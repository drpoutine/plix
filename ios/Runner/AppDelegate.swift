import Flutter
import UIKit
import AVFoundation

@objc(SceneDelegate)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    DispatchQueue.main.async { [weak self] in
      let controller = (self?.window?.rootViewController as? FlutterViewController)
        ?? (windowScene.windows.compactMap { $0.rootViewController as? FlutterViewController }.first)
        ?? (UIApplication.shared.windows.compactMap { $0.rootViewController as? FlutterViewController }.first)

      if let controller = controller, let appDelegate = UIApplication.shared.delegate as? AppDelegate {
        appDelegate.configureFlutterViewController(controller)
      }
    }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.handleOrientationOrLayoutChange()
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var channel: FlutterMethodChannel?

  // iPhone Duo state. See "iPhone Duo support" below.
  private var duoChannel: FlutterMethodChannel?
  private weak var duoController: FlutterViewController?
  private weak var duoProbe: UIView?
  private var duoHingeSeen = false
  private var duoHingeStatus = "unknown"
  private var duoHingeAngle = 0.0
  private var duoPublishScheduled = false
  private var lastDuoInfo: NSDictionary?
  private var isConfigured = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    setupAudioSession()

    if let controller = window?.rootViewController as? FlutterViewController {
      configureFlutterViewController(controller)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - UISceneSession Lifecycle
  override func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    config.delegateClass = SceneDelegate.self
    return config
  }

  func configureFlutterViewController(_ controller: FlutterViewController) {
    guard !isConfigured else { return }
    isConfigured = true

    controller.isViewOpaque = false
    controller.view.backgroundColor = .clear

    let nativeChannel = FlutterMethodChannel(name: "com.plix.plix/native_player", binaryMessenger: controller.binaryMessenger)
    self.channel = nativeChannel

    nativeChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      self?.handleMethodCall(call: call, result: result, controller: controller)
    }

    setupDuoSupport(controller: controller)
  }

  /// Called by the scene delegate when the scene becomes active.
  @objc func handleOrientationOrLayoutChange() {
    scheduleDuoPublish()
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

  private lazy var isDuoModel: Bool = getDeviceIdentifier() == "iPhone19,4"

  /// The model identifier, or the system having reported a hinge. Other
  /// iPhone19,x models are ordinary phones, so the family prefix is not used.
  private var isIphoneDuo: Bool { isDuoModel || duoHingeSeen }

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

    #if compiler(>=6.4)
    if #available(iOS 27.1, *) {
      let interaction = UIHingeInteraction { [weak self] _, update in
        // Leave the callback before touching state that drives layout.
        Task { @MainActor in
          guard let self = self else { return }
          if let hinge = update.hinge {
            self.duoHingeSeen = true
            switch hinge.status {
            case .closed: self.duoHingeStatus = "closed"
            case .partiallyOpen: self.duoHingeStatus = "partiallyOpen"
            case .fullyOpen: self.duoHingeStatus = "fullyOpen"
            @unknown default: self.duoHingeStatus = "unknown"
            }
            // Rounded to a tenth of a radian: layout follows the status, and
            // an unrounded angle would send a message per frame while folding.
            self.duoHingeAngle = (Double(hinge.angle) * 10.0).rounded() / 10.0
          } else {
            self.duoHingeStatus = "unknown"
            self.duoHingeAngle = 0.0
          }
          self.installDuoLayoutProbeIfNeeded()
          self.scheduleDuoPublish()
        }
      }
      controller.view.addInteraction(interaction)
    }
    #endif

    installDuoLayoutProbeIfNeeded()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDuoEnvironmentChange),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    // With the scene lifecycle this can run after Dart has already asked for
    // the info and found no handler, so the first state is always pushed.
    scheduleDuoPublish()
  }

  /// Layout probe, installed only on an iPhone Duo: rotation, moving between
  /// the outer and inner display and reserved-region changes all arrive as a
  /// layout pass. UIKit re-runs layout for a view that read a reserved region
  /// once that region changes, which is the only signal for the fold band
  /// settling after the hinge comes to rest.
  private func installDuoLayoutProbeIfNeeded() {
    guard isIphoneDuo, duoProbe == nil, let controller = duoController else { return }
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
    duoProbe = probe
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
    let windowScene = view.window?.windowScene
    var isLandscape = width > height
    #if compiler(>=6.4)
    if #available(iOS 27.1, *), let orientation = windowScene?.effectiveGeometry.interfaceOrientation {
      isLandscape = orientation.isLandscape
    } else if let orientation = windowScene?.interfaceOrientation {
      isLandscape = orientation.isLandscape
    }
    #else
    if let orientation = windowScene?.interfaceOrientation {
      isLandscape = orientation.isLandscape
    }
    #endif

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

  /// The active fold band from UIKit's reserved regions (iOS 27.1), in
  /// `view`'s coordinates, or nil when the system reports none. The region's
  /// `isActive` lags the hinge, so the pose itself is decided from the hinge
  /// and Dart falls back to the mid line until a region arrives.
  private func divisionRegionFrame(in view: UIView) -> CGRect? {
    #if compiler(>=6.4)
    if #available(iOS 27.1, *) {
      guard view.window != nil else { return nil }
      for region in view.reservedRegions(kind: .division) where region.isActive {
        let frame = region.frame
        if frame.width > 0, frame.height > 0, !frame.isInfinite, !frame.isNull {
          return frame
        }
      }
    }
    #endif
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
