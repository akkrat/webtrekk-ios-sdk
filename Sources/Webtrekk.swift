import UIKit
import ReachabilitySwift

public final class Webtrekk : Logable {

	public static let sharedInstance = Webtrekk()
	internal lazy var loger: Loger = Loger()

	public var advertisingIdentifier: (() -> String?)? {
		didSet {
			queue?.advertisingIdentifier = advertisingIdentifier
		}
	}

	public var enableLoging: Bool = false {
		didSet {
			guard oldValue != enableLoging else {
				return
			}
			loger.enabled = enableLoging
		}
	}

	public var config: TrackerConfiguration? {
		didSet {
			guard oldValue?.optedOut != config?.optedOut else {
				return
			}
			if oldValue == nil {
				setUp()
			}

			guard config != nil else {
				return
			}
			queue?.shouldTrack = shouldTrack()

		}
	}

	public var flush: Bool = false{
		didSet {
			if flush {
				self.flush = false
				queue?.flushNow()
			}
		}
	}

	public var crossDeviceBridge: CrossDeviceBridgeParameter?

	private var plugins = [String: WebtrekkPlugin]()
	private var hibernationObserver: NSObjectProtocol?
	private var wakeUpObserver: NSObjectProtocol?
	private var queue: SendQueue?
	private lazy var fileManager: FileManager = FileManager(self.loger)

	// MARK: Lifecycle

	deinit {
		if let hibernationObserver = hibernationObserver {
			NSNotificationCenter.defaultCenter().removeObserver(hibernationObserver)
		}
		if let wakeUpObserver = wakeUpObserver {
			NSNotificationCenter.defaultCenter().removeObserver(wakeUpObserver)
		}
	}

	private init() {

	}

	public convenience init(configParser: ConfigParser) throws {
		guard let config = configParser.trackerConfiguration else {
			throw WebtrekkError.InitParserError
		}
		self.init(config: config)
	}


	public init(config: TrackerConfiguration) {
		self.config = config
		setUp()
	}


	private func setUp() {
		setUpConfig()
		setUpQueue()
		setUpOptedOut()
	}


	private func setUpConfig() {
		guard let config = self.config else {
			return
		}
		// check if there is a local dump of the config saved
		if let localConfig = fileManager.restoreConfiguration(config.trackingId) where localConfig.version > config.version{
			self.config = localConfig
		}
		else {
			fileManager.saveConfiguration(config)
		}

		guard config.enableRemoteConfiguration && !config.remoteConfigurationUrl.isEmpty, let url = NSURL(string: config.remoteConfigurationUrl) else {
			return
		}

		let httpClient = DefaultHttpClient()
		httpClient.get(url) { (data, error) -> Void in
			guard let xmlData = data else {
				self.log("No data could be retrieved from \(self.config?.remoteConfigurationUrl).")
				return
			}
			guard let xmlString = String(data: xmlData, encoding: NSUTF8StringEncoding) else {
				self.log("Cannot parse data retreived from \(self.config?.remoteConfigurationUrl)")
				return
			}

			let config: TrackerConfiguration!
			do {
				let parser = try XmlConfigParser(xmlString: xmlString)
				config = parser.trackerConfiguration
			} catch {
				self.log("\(WebtrekkError.RemoteParserError)")
				return
			}


			guard config.version > self.config?.version else {
				self.log("Remote configuration is not newer then the currently used.")
				return
			}
			self.log("Updating tracker config from version \(self.config?.version) to new version \(config.version)")
			self.config = config
			self.fileManager.saveConfiguration(config)
		}
	}


	private func setUpOptedOut() {
		config?.optedOut =	NSUserDefaults.standardUserDefaults().boolForKey(UserStoreKey.OptedOut)
	}


	private func setUpQueue() {
		guard let config = config else {
			return
		}
		let backupFileUrl: NSURL = fileManager.getConfigurationDirectoryUrl(forTrackingId: config.trackingId).URLByAppendingPathComponent("queue.json")
		queue = SendQueue(backupFileUrl: backupFileUrl, sendDelay: config.sendDelay, maximumUrlCount: config.maxRequests, loger: loger)
		queue?.shouldTrack = shouldTrack()
	}


	func shouldTrack() -> Bool {
		guard let config = config else {
			return false
		}
		let userDefaults = NSUserDefaults.standardUserDefaults()
		let userShouldBeSampled: Bool
		if let _ = userDefaults.objectForKey(UserStoreKey.Sampled.rawValue) {
			userShouldBeSampled = userDefaults.boolForKey(UserStoreKey.Sampled)
		}
		else {
			userShouldBeSampled = (config.samplingRate == 0) || (Int64(arc4random()) % Int64(config.samplingRate) == 0)
			userDefaults.setBool(userShouldBeSampled, forKey: UserStoreKey.Sampled.rawValue)
		}
		return userShouldBeSampled && !config.optedOut
	}

	// MARK: Tracking

	public func autoTrack(className: String) throws {
		guard let config = config where config.autoTrack else {
			return
		}

		for (key, screen) in config.autoTrackScreens {
			guard className.containsString(key) else {
				continue
			}
			guard screen.enabled else {
				return
			}
			try track(screen)
			return
		}
		try track(className)
	}


	public func track(pageName: String) throws {
		try track(PageTrackingParameter(pageName: pageName))
	}


	public func track(trackingParameter: TrackingParameter) throws {
		guard let config = config else {
			throw WebtrekkError.NoTrackerConfiguration
		}
		var preparedConfig = config
		if let crossDeviceBridge = crossDeviceBridge {
			preparedConfig.crossDeviceParameters = crossDeviceBridge.toParameter()
		}
		var parameter = trackingParameter
		parameter.generalParameter.firstStart = trackingParameter.firstStart()
		enqueue(parameter, config: preparedConfig)
	}


	private func track(screen: AutoTrackedScreen) throws {
		if let pageTrackingParameter = screen.pageTrackingParameter {
			try track(pageTrackingParameter)
		}
		else {
			try track(screen.mappingName)
		}
	}


	private func enqueue(trackingParameter: TrackingParameter, config: TrackerConfiguration) {
		let preparedConfig = self.prepare(config)
		var enhancedTrackingParameter = trackingParameter
		enhancedTrackingParameter.generalParameter.samplingRate = preparedConfig.samplingRate
		let parameter = handleBeforePluginCall(enhancedTrackingParameter)
		if shouldTrack() {
			queue?.add(parameter, config: preparedConfig)
		}
		handleAfterPluginCall(parameter)
	}


	private func prepare(config: TrackerConfiguration) -> TrackerConfiguration{
		// TODO: Rename parameter names to the correct ones
		var urlString = ""
		if config.autoTrack {
			if config.autoTrackAdvertiserId, let advertisingIdentifier = advertisingIdentifier, let id = advertisingIdentifier() {
				urlString += "&\(ParameterName.urlParameter(fromName: .AdvertiserId, andValue: id))"
			}

			if config.autoTrackConnectionType, let reachability = try? Reachability.reachabilityForInternetConnection() {
				urlString += "&\(ParameterName.urlParameter(fromName: .ConnectionType, andValue: reachability.isReachableViaWiFi() ? "0" : "1"))"
			}

			if config.autoTrackRequestUrlStoreSize, let queue = queue {
				urlString += "&\(ParameterName.urlParameter(fromName: .RequestUrlStoreSize, andValue: "\(queue.itemCount)"))"
			}

			if config.autoTrackAppVersionName {
				if let version = NSBundle.mainBundle().infoDictionary?["CFBundleShortVersionString"] as? String {
					urlString += "&\(ParameterName.urlParameter(fromName: .AppVersionName, andValue: config.appVersion.isEmpty ? version : config.appVersion))"
				}
			}

			if config.autoTrackAppVersionCode {
				if let version = NSBundle.mainBundle().infoDictionary?[kCFBundleVersionKey as String] as? String {
					urlString += "&\(ParameterName.urlParameter(fromName: .AppVersionCode, andValue: version))"
				}
			}

			if config.autoTrackScreenOrientation {
				urlString += "&\(ParameterName.urlParameter(fromName: .ScreenOrientation, andValue: UIDeviceOrientationIsLandscape(UIDevice.currentDevice().orientation) ? "1" : "0"))"
			}

			if config.autoTrackAppUpdate {
				var appVersion: String
				if !config.appVersion.isEmpty {
					appVersion = config.appVersion
				} else if let version = NSBundle.mainBundle().infoDictionary?["CFBundleShortVersionString"] as? String {
					appVersion = version
				}else {
					appVersion = ""
				}

				let userDefaults = NSUserDefaults.standardUserDefaults()
				if let version = userDefaults.stringForKey(UserStoreKey.VersionNumber) {
					if version != appVersion {
						userDefaults.setValue(appVersion, forKey:UserStoreKey.VersionNumber.rawValue)
						urlString += "&\(ParameterName.urlParameter(fromName: .AppUpdate, andValue: "1"))"
					}
				} else {
					userDefaults.setValue(appVersion, forKey:UserStoreKey.VersionNumber.rawValue)
				}
			}
		}
		var confCopy = config
		confCopy.onQueueAutoTrackParameters = urlString.isEmpty ? nil : urlString
		return confCopy
	}
}


public protocol WebtrekkPlugin: class {
	var id: String { get set }

	func beforeTrackingSend (parameter: TrackingParameter) -> TrackingParameter
	func afterTrackingSend  (parameter: TrackingParameter)
}


public enum WebtrekkError: ErrorType {
	case InitError
	case InitParserError
	case NoTrackerConfiguration
	case RemoteParserError
}


extension Webtrekk {

	// MARK: Plugins

	public func addPlugin(plugin: WebtrekkPlugin){
		guard let found = plugins[plugin.id] where found === plugin else {
			plugins[plugin.id] = plugin
			return
		}
		fatalError("The Plugin with the id:\"\(plugin.id)\" was already added.")
	}


	public func removePlugin(plugin: WebtrekkPlugin) -> Bool {
		guard let found = plugins.removeValueForKey(plugin.id) else {
			return false
		}
		return found === plugin
	}


	public func removeAllPlugins() -> Bool {
		plugins.removeAll()
		return plugins.isEmpty
	}


	internal func handleAfterPluginCall(trackingParameter: TrackingParameter) {
		guard !plugins.isEmpty else {
			return
		}

		for (_, plugin) in plugins {
			plugin.afterTrackingSend(trackingParameter)
		}
	}


	internal func handleBeforePluginCall(trackingParameter: TrackingParameter) -> TrackingParameter {
		guard !plugins.isEmpty else {
			return trackingParameter
		}
		var parameter = trackingParameter
		for (_, plugin) in plugins {
			parameter = plugin.beforeTrackingSend(parameter)
		}
		return parameter
	}
}