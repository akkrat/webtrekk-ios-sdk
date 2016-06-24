#if !os(watchOS)
	import AVFoundation
#endif


public protocol PageTracker: class {

	var advertisementProperties: AdvertisementProperties { get set }
	var customProperties: [String : String] { get set }
	var ecommerceProperties: EcommerceProperties { get set }
	var pageProperties: PageProperties { get set }


	func trackAction (actionName: String)

	func trackAction (event: ActionEvent)

	func trackMedia (event: MediaEvent)

	@warn_unused_result
	func trackMedia (mediaName: String) -> MediaTracker

	#if !os(watchOS)
	func trackMedia (mediaName: String, byAttachingToPlayer player: AVPlayer) -> MediaTracker
	#endif

	func trackPageView ()
}


public extension PageTracker {

	public func trackAction(actionName: String) {
		trackAction(ActionEvent(actionProperties: ActionProperties(name: actionName), pageProperties: pageProperties))
	}
}
