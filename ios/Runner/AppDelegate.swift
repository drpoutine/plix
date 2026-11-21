import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var channel: FlutterMethodChannel?

  // iPhone Duo state. See "iPhone Duo support" below.
  private var duoChannel: FlutterMethodChannel?
  private weak var duoController: FlutterViewController?
  private var duoHingeStatus = "unknown"
  private var duoHingeAngle = 0.0
  private var duoPublishScheduled = false
  private var lastDuoInfo: NSDictionary?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    setupAudioSession()

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    controller.isViewOpaque = false
    controller.view.backgroundColor = .clear

    let nativeChannel = FlutterMethodChannel(name: "com.plix.plix/native_player", binaryMessenger: controller.binaryMessenger)
    self.channel = nativeChannel

    nativeChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      self?.handleMethodCall(call: call, result: result, controller: controller)
    }

    setupDuoSupport(controller: controller)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func setupAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("AVAudioSession error: \(error)")
    }
  }

  private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult, controller: FlutterViewController) {
    switch call.method {
    case "play", "pause", "resume", "seekTo", "stop", "setPlaybackSpeed", "setVideoBounds", "setSubtitleTrack", "setAudioTrack":
      result(true)

    case "enterPipMode":
      result(false)

    case "getState":
      result([
        "position": 0,
        "duration": 0,
        "isPlaying": false,
        "buffered": 0
      ])

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - iPhone Duo support
  //
  // Apple reports a hinge (closed / partially open / fully open), not a pose.
  // This side forwards the raw facts and Dart derives the pose from them
  // together with the interface orientation (IPhoneDuoInfo.resolvePosture):
  //
  //   isDuo      the device is an iPhone Duo
  //   hinge      UIHingeInteraction status, "unknown" when there is no reading
  //   angle      hinge angle in radians, 0 shut, pi flat
  //   inner      the app is on the inner display
  //   landscape  interface orientation
  //   fold       the system's .division reserved region, when it reports one
  //
  // Updates are sent on their own channel so they reach Dart on every screen.

  private func getDeviceIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    let identifier = machineMirror.children.reduce("") { identifier, element in
      guard let value = element.value as? Int8, value != 0 else { return identifier }
      return identifier + String(UnicodeScalar(UInt8(value)))
    }
    #if targetEnvironment(simulator)
    if let simId = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simId
    }
    #endif
    return identifier
  }

  private lazy var isIphoneDuo: Bool = getDeviceIdentifier() == "iPhone19,4"

  private func setupDuoSupport(controller: FlutterViewController) {
    duoController = controller

    let duo = FlutterMethodChannel(name: "com.plix.plix/duo", binaryMessenger: controller.binaryMessenger)
    duoChannel = duo
    duo.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(["isDuo": false])
        return
      }
      switch call.method {
      case "getDuoInfo":
        let info = self.currentDuoInfo()
        self.lastDuoInfo = info as NSDictionary
        result(info)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Nothing below is installed on any other device.
    guard isIphoneDuo else { return }

    // Layout probe: rotation, moving between the outer and inner display and
    // reserved-region changes all arrive as a layout pass. UIKit re-runs
    // layout for a view that read a reserved region once that region changes,
    // which is the only signal there is for the fold band settling.
    let probe = DuoLayoutProbeView(frame: controller.view.bounds)
    probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    probe.isUserInteractionEnabled = false
    probe.backgroundColor = .clear
    probe.isOpaque = false
    probe.onLayout = { [weak self, weak probe] in
      guard let self = self else { return }
      if let probe = probe { _ = self.divisionRegionFrame(in: probe) }
      self.scheduleDuoPublish()
    }
    controller.view.insertSubview(probe, at: 0)

    #if compiler(>=6.4)
    if #available(iOS 27.1, *) {
      let interaction = UIHingeInteraction { [weak self] _, update in
        guard let self = self else { return }
        if let hinge = update.hinge {
          switch hinge.status {
          case .closed: self.duoHingeStatus = "closed"
          case .partiallyOpen: self.duoHingeStatus = "partiallyOpen"
          case .fullyOpen: self.duoHingeStatus = "fullyOpen"
          default: self.duoHingeStatus = "unknown"
          }
          // Rounded to a tenth of a radian: layout follows the status, and an
          // unrounded angle would send a message per frame while folding.
          self.duoHingeAngle = (Double(hinge.angle) * 10.0).rounded() / 10.0
        } else {
          self.duoHingeStatus = "unknown"
          self.duoHingeAngle = 0.0
        }
        self.scheduleDuoPublish()
      }
      controller.view.addInteraction(interaction)
    }
    #endif

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDuoEnvironmentChange),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  @objc private func handleDuoEnvironmentChange() {
    scheduleDuoPublish()
  }

  /// Publishes outside the layout pass and the hinge callback, coalescing
  /// bursts into one message, and only when something changed.
  private func scheduleDuoPublish() {
    if duoPublishScheduled { return }
    duoPublishScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.duoPublishScheduled = false
      let info = self.currentDuoInfo() as NSDictionary
      if let last = self.lastDuoInfo, last.isEqual(info) { return }
      self.lastDuoInfo = info
      self.duoChannel?.invokeMethod("onDuoInfoChanged", arguments: info)
    }
  }

  private func currentDuoInfo() -> [String: Any] {
    guard isIphoneDuo, let controller = duoController, let view = controller.viewIfLoaded else {
      return ["isDuo": false]
    }

    let bounds = view.bounds
    let width = Double(bounds.width)
    let height = Double(bounds.height)

    // The interface orientation comes from the scene. The device orientation
    // is a quarter turn off on the inner display.
    var isLandscape = width > height
    if let scene = view.window?.windowScene {
      if #available(iOS 16.0, *) {
        isLandscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
      } else {
        isLandscape = scene.interfaceOrientation.isLandscape
      }
    }

    // Outer display: 466 x 678 pt. Inner display: 669 x 951 pt.
    let isInnerDisplay = max(width, height) > 800 || min(width, height) > 550

    var info: [String: Any] = [
      "isDuo": true,
      "hinge": duoHingeStatus,
      "angle": duoHingeAngle,
      "inner": isInnerDisplay,
      "landscape": isLandscape,
    ]
    if isInnerDisplay, let fold = divisionRegionFrame(in: view) {
      info["fold"] = [
        "x": Double(fold.origin.x),
        "y": Double(fold.origin.y),
        "width": Double(fold.size.width),
        "height": Double(fold.size.height),
      ]
    }
    return info
  }

  /// The fold band from UIKit's reserved regions (iOS 27.1), in `view`'s
  /// coordinates, or nil when the system does not provide one.
  ///
  /// Resolved through the Objective-C runtime so this file builds with any
  /// Xcode:
  ///
  ///   -[UIView reservedRegionsOfKind:(UIViewReservedRegionKind *)kind
  ///                          options:(UIViewReservedRegionQueryOptions)options]
  ///   +[UIViewReservedRegionKind divisionRegionKind]
  ///   UIViewReservedRegion.frame
  ///
  /// The band is requested including inactive regions, because `isActive`
  /// lags the hinge. Whether the fold is in effect is decided from the hinge.
  private func divisionRegionFrame(in view: UIView) -> CGRect? {
    let selector = NSSelectorFromString("reservedRegionsOfKind:options:")
    guard view.responds(to: selector),
          let kindClass = NSClassFromString("UIViewReservedRegionKind") as? NSObject.Type
    else { return nil }

    let kindSelector = NSSelectorFromString("divisionRegionKind")
    let kindClassObject: AnyObject = kindClass
    guard kindClassObject.responds(to: kindSelector),
          let kind = kindClassObject.perform(kindSelector)?.takeUnretainedValue()
    else { return nil }

    guard let implementation = view.method(for: selector) else { return nil }
    typealias ReservedRegionsFunction =
      @convention(c) (AnyObject, Selector, AnyObject, UInt) -> Unmanaged<AnyObject>?
    let function = unsafeBitCast(implementation, to: ReservedRegionsFunction.self)
    let includeInactive: UInt = 1 << 0
    guard let regions = function(view, selector, kind, includeInactive)?.takeUnretainedValue() as? [NSObject]
    else { return nil }

    let frameSelector = NSSelectorFromString("frame")
    for region in regions where region.responds(to: frameSelector) {
      guard let frame = (region.value(forKey: "frame") as? NSValue)?.cgRectValue else { continue }
      if frame.width > 0, frame.height > 0, !frame.isInfinite, !frame.isNull {
        return frame
      }
    }
    return nil
  }
}

/// A transparent, non-interactive view whose only job is to report layout
/// passes of the Flutter view it is pinned to.
private final class DuoLayoutProbeView: UIView {
  var onLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}
