import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The pose Plix lays out for on an iPhone Duo.
///
/// Apple reports a hinge (closed / partially open / fully open), not a pose.
/// The pose is derived from the hinge plus the interface orientation:
///
/// | Hinge          | Orientation | Pose        |
/// |----------------|-------------|-------------|
/// | closed         | any         | [closed]    |
/// | fully open     | any         | [fullyOpen] |
/// | partially open | portrait    | [tabletop]  |
/// | partially open | landscape   | [book]      |
enum DuoPosture {
  /// Not an iPhone Duo.
  none,

  /// Folded shut: the app is on the outer (cover) display.
  closed,

  /// Inner display, laid flat. The fold reserves no space.
  fullyOpen,

  /// Half folded, held upright: the fold runs left to right across the middle.
  tabletop,

  /// Half folded, on its side: the fold runs top to bottom like a book spine.
  book,
}

/// Mirrors UIKit's `UIHingeStatus`.
enum DuoHingeStatus { unknown, closed, partiallyOpen, fullyOpen }

/// The fold band for the current pose, in logical pixels of the Flutter view.
@immutable
class DuoFold {
  /// The area the fold reserves. Keep buttons and text out of it; scrolling
  /// content may pass through.
  final Rect band;

  /// [Axis.horizontal] when the band runs left to right (tabletop),
  /// [Axis.vertical] when it runs top to bottom (book).
  final Axis axis;

  const DuoFold({required this.band, required this.axis});

  bool get isTabletop => axis == Axis.horizontal;
  bool get isBook => axis == Axis.vertical;

  /// Tabletop: the y where the upper half ends. Book: the x where the left
  /// half ends.
  double get start => axis == Axis.horizontal ? band.top : band.left;

  /// Tabletop: the y where the lower half begins. Book: the x where the right
  /// half begins.
  double get end => axis == Axis.horizontal ? band.bottom : band.right;

  @override
  bool operator ==(Object other) =>
      other is DuoFold && other.band == band && other.axis == axis;

  @override
  int get hashCode => Object.hash(band, axis);

  @override
  String toString() => 'DuoFold($axis, $band)';
}

@immutable
class IPhoneDuoInfo {
  /// Width of the fold band measured on the iPhone Duo simulator: 20pt either
  /// side of the fold line. Used when the system does not report a region.
  static const double defaultFoldBand = 40.0;

  final bool isDuo;
  final DuoHingeStatus hinge;

  /// Hinge angle in radians: 0 folded shut, pi laid flat.
  final double hingeAngle;

  /// Whether the app is on the inner display.
  final bool isInnerDisplay;

  /// Interface orientation as last reported by the platform. Layout code
  /// should prefer the `MediaQuery` orientation via [postureFor].
  final bool isLandscape;

  /// The system's `.division` reserved region, when it reports one.
  final Rect? foldRect;

  /// A pose forced from the debug simulator, overriding the hinge.
  final DuoPosture? simulatedPosture;

  const IPhoneDuoInfo({
    this.isDuo = false,
    this.hinge = DuoHingeStatus.unknown,
    this.hingeAngle = 0.0,
    this.isInnerDisplay = false,
    this.isLandscape = false,
    this.foldRect,
    this.simulatedPosture,
  });

  /// Pure pose decision. Kept free of platform state so it can be unit tested.
  static DuoPosture resolvePosture({
    required bool isDuo,
    required DuoHingeStatus hinge,
    required bool isInnerDisplay,
    required bool isLandscape,
  }) {
    if (!isDuo) return DuoPosture.none;
    if (!isInnerDisplay) return DuoPosture.closed;
    switch (hinge) {
      case DuoHingeStatus.closed:
        return DuoPosture.closed;
      case DuoHingeStatus.partiallyOpen:
        return isLandscape ? DuoPosture.book : DuoPosture.tabletop;
      case DuoHingeStatus.fullyOpen:
      case DuoHingeStatus.unknown:
        // No hinge reading (older OS or SDK): the inner display is treated as
        // flat, never as folded.
        return DuoPosture.fullyOpen;
    }
  }

  /// The pose for a given interface orientation.
  DuoPosture postureFor(Orientation orientation) {
    final landscape = orientation == Orientation.landscape;
    final sim = simulatedPosture;
    if (sim != null) {
      // A simulated half-fold still follows the real orientation, exactly as
      // the hardware does.
      if (sim == DuoPosture.tabletop || sim == DuoPosture.book) {
        return landscape ? DuoPosture.book : DuoPosture.tabletop;
      }
      return sim;
    }
    return resolvePosture(
      isDuo: isDuo,
      hinge: hinge,
      isInnerDisplay: isInnerDisplay,
      isLandscape: landscape,
    );
  }

  /// The pose using the platform-reported orientation.
  DuoPosture get posture =>
      postureFor(isLandscape ? Orientation.landscape : Orientation.portrait);

  /// The fold band for a view of [size], or null when nothing is reserved
  /// (not a Duo, closed, or laid flat).
  DuoFold? foldFor(Size size) {
    if (size.isEmpty) return null;
    final orientation =
        size.width > size.height ? Orientation.landscape : Orientation.portrait;
    final p = postureFor(orientation);
    if (p != DuoPosture.tabletop && p != DuoPosture.book) return null;
    final axis = p == DuoPosture.tabletop ? Axis.horizontal : Axis.vertical;

    final reported = foldRect;
    if (reported != null && simulatedPosture == null) {
      final matchesAxis = axis == Axis.horizontal
          ? reported.width >= reported.height
          : reported.height > reported.width;
      final inside = reported.left >= -0.5 &&
          reported.top >= -0.5 &&
          reported.right <= size.width + 0.5 &&
          reported.bottom <= size.height + 0.5;
      final thickness =
          axis == Axis.horizontal ? reported.height : reported.width;
      if (matchesAxis && inside && thickness > 0) {
        // The reported region can be stale for a moment after a rotation, so
        // it is only trusted when it fits the current view and pose.
        final band = axis == Axis.horizontal
            ? Rect.fromLTRB(0, reported.top, size.width, reported.bottom)
            : Rect.fromLTRB(reported.left, 0, reported.right, size.height);
        return DuoFold(band: band, axis: axis);
      }
    }

    const half = defaultFoldBand / 2.0;
    final band = axis == Axis.horizontal
        ? Rect.fromLTRB(
            0, size.height / 2.0 - half, size.width, size.height / 2.0 + half)
        : Rect.fromLTRB(
            size.width / 2.0 - half, 0, size.width / 2.0 + half, size.height);
    return DuoFold(band: band, axis: axis);
  }

  static DuoHingeStatus _parseHinge(String? value) {
    switch (value) {
      case 'closed':
        return DuoHingeStatus.closed;
      case 'partiallyOpen':
        return DuoHingeStatus.partiallyOpen;
      case 'fullyOpen':
        return DuoHingeStatus.fullyOpen;
      default:
        return DuoHingeStatus.unknown;
    }
  }

  static DuoPosture? _parsePosture(String? value) {
    switch (value) {
      case 'closed':
        return DuoPosture.closed;
      case 'fullyOpen':
        return DuoPosture.fullyOpen;
      case 'tabletop':
        return DuoPosture.tabletop;
      case 'book':
        return DuoPosture.book;
      default:
        return null;
    }
  }

  /// Parses the platform payload:
  ///
  /// ```
  /// { isDuo, hinge: closed|partiallyOpen|fullyOpen|unknown, angle (radians),
  ///   inner, landscape, fold: {x, y, width, height}? }
  /// ```
  factory IPhoneDuoInfo.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const IPhoneDuoInfo();
    final isDuo = map['isDuo'] as bool? ?? false;
    if (!isDuo) return const IPhoneDuoInfo();

    Rect? fold;
    final rawFold = map['fold'];
    if (rawFold is Map) {
      final x = (rawFold['x'] as num?)?.toDouble();
      final y = (rawFold['y'] as num?)?.toDouble();
      final w = (rawFold['width'] as num?)?.toDouble();
      final h = (rawFold['height'] as num?)?.toDouble();
      if (x != null &&
          y != null &&
          w != null &&
          h != null &&
          w.isFinite &&
          h.isFinite &&
          x.isFinite &&
          y.isFinite &&
          w > 0 &&
          h > 0) {
        fold = Rect.fromLTWH(x, y, w, h);
      }
    }

    return IPhoneDuoInfo(
      isDuo: true,
      hinge: _parseHinge(map['hinge'] as String?),
      hingeAngle: (map['angle'] as num?)?.toDouble() ?? 0.0,
      isInnerDisplay: map['inner'] as bool? ?? false,
      isLandscape: map['landscape'] as bool? ?? false,
      foldRect: fold,
      simulatedPosture: _parsePosture(map['simulatedPosture'] as String?),
    );
  }

  IPhoneDuoInfo withSimulatedPosture(DuoPosture? posture) {
    final sim = posture == DuoPosture.none ? null : posture;
    return IPhoneDuoInfo(
      isDuo: sim != null ? true : isDuo,
      hinge: hinge,
      hingeAngle: hingeAngle,
      isInnerDisplay: isInnerDisplay,
      isLandscape: isLandscape,
      foldRect: foldRect,
      simulatedPosture: sim,
    );
  }

  /// Whether [other] lays out identically: everything except the hinge angle,
  /// which moves continuously while the phone is being folded.
  bool sameLayoutAs(IPhoneDuoInfo other) =>
      other.isDuo == isDuo &&
      other.hinge == hinge &&
      other.isInnerDisplay == isInnerDisplay &&
      other.isLandscape == isLandscape &&
      other.foldRect == foldRect &&
      other.simulatedPosture == simulatedPosture;

  @override
  bool operator ==(Object other) =>
      other is IPhoneDuoInfo &&
      other.isDuo == isDuo &&
      other.hinge == hinge &&
      other.hingeAngle == hingeAngle &&
      other.isInnerDisplay == isInnerDisplay &&
      other.isLandscape == isLandscape &&
      other.foldRect == foldRect &&
      other.simulatedPosture == simulatedPosture;

  @override
  int get hashCode => Object.hash(isDuo, hinge, hingeAngle, isInnerDisplay,
      isLandscape, foldRect, simulatedPosture);
}

class IPhoneDuoService {
  /// Dedicated channel, so hinge updates reach Dart on every screen and not
  /// only while a player owns the playback channel.
  static const MethodChannel _channel = MethodChannel('com.plix.plix/duo');

  static bool _initialized = false;
  static bool get isInitialized => _initialized;

  /// The info as reported by the platform, before any simulation.
  static IPhoneDuoInfo _hardwareInfo = const IPhoneDuoInfo();
  static DuoPosture? _simulated;

  static final ValueNotifier<IPhoneDuoInfo> _notifier =
      ValueNotifier<IPhoneDuoInfo>(const IPhoneDuoInfo());
  static final _postureController =
      StreamController<IPhoneDuoInfo>.broadcast();

  /// Listen to this to rebuild on any hinge, display or simulation change.
  static ValueListenable<IPhoneDuoInfo> get listenable => _notifier;

  static IPhoneDuoInfo get currentInfo => _notifier.value;
  static bool get isDuo => _notifier.value.isDuo;
  static DuoPosture get currentPosture => _notifier.value.posture;
  static DuoPosture? get simulatedPosture => _simulated;
  static Stream<IPhoneDuoInfo> get onPostureChanged =>
      _postureController.stream;

  /// Anchor for sheets and dialogs that belong with the app's content: the
  /// lower half in tabletop, the left half in book.
  static const Offset sheetAnchor = Offset(0, double.maxFinite);

  /// Anchor for sheets that belong with playback controls: the lower half in
  /// tabletop, the right half in book.
  static const Offset controlsAnchor =
      Offset(double.maxFinite, double.maxFinite);

  static Future<IPhoneDuoInfo> init() async {
    if (!Platform.isIOS) return currentInfo;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final res =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getDuoInfo');
      _hardwareInfo = IPhoneDuoInfo.fromMap(res);
      _initialized = true;
    } catch (_) {
      _hardwareInfo = const IPhoneDuoInfo();
    }
    _publish();
    return currentInfo;
  }

  static Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onDuoInfoChanged') {
      updateFromNative(call.arguments as Map<dynamic, dynamic>?);
    }
    return null;
  }

  static void updateFromNative(Map<dynamic, dynamic>? map) {
    _hardwareInfo = IPhoneDuoInfo.fromMap(map);
    _publish();
  }

  static void _publish() {
    final next = _hardwareInfo.withSimulatedPosture(_simulated);
    if (next == _notifier.value) return;
    _notifier.value = next;
    _postureController.add(next);
  }

  /// Forces a pose for layout work without the hardware. Pass null (or
  /// [DuoPosture.none]) to return to the real hinge. Works on every platform,
  /// so layouts can be checked on desktop and in widget tests.
  static Future<void> setSimulatedPosture(DuoPosture? posture) async {
    _simulated = posture == DuoPosture.none ? null : posture;
    _publish();
  }

  /// Restores a pristine state. For tests.
  @visibleForTesting
  static void debugReset() {
    _simulated = null;
    _hardwareInfo = const IPhoneDuoInfo();
    _publish();
  }

  static IPhoneDuoInfo _infoOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<DuoInheritedInfo>();
    return scope?.info ?? currentInfo;
  }

  /// The pose for [context], rebuilding it when the pose changes.
  static DuoPosture postureOf(BuildContext context) {
    final info = _infoOf(context);
    if (!info.isDuo) return DuoPosture.none;
    return info.postureFor(MediaQuery.orientationOf(context));
  }

  /// The fold band in the coordinates of the whole view, or null when the
  /// fold reserves nothing. Rebuilds [context] when it changes.
  static DuoFold? foldOf(BuildContext context) {
    final info = _infoOf(context);
    if (!info.isDuo) return null;
    return info.foldFor(MediaQuery.sizeOf(context));
  }

  /// True only on an iPhone Duo that is half folded and held upright.
  static bool isTabletop(BuildContext context) =>
      postureOf(context) == DuoPosture.tabletop;

  /// True only on an iPhone Duo that is half folded and on its side.
  static bool isBook(BuildContext context) =>
      postureOf(context) == DuoPosture.book;

  /// True on the inner display, flat or half folded.
  static bool isInnerDisplay(BuildContext context) {
    final p = postureOf(context);
    return p == DuoPosture.fullyOpen ||
        p == DuoPosture.tabletop ||
        p == DuoPosture.book;
  }
}

/// Carries the current [IPhoneDuoInfo] down the tree so that widgets reading
/// [IPhoneDuoService.postureOf] or [IPhoneDuoService.foldOf] rebuild when the
/// hinge moves. Installed once by `DuoScope`.
class DuoInheritedInfo extends InheritedWidget {
  final IPhoneDuoInfo info;

  const DuoInheritedInfo({super.key, required this.info, required super.child});

  @override
  bool updateShouldNotify(DuoInheritedInfo oldWidget) =>
      !oldWidget.info.sameLayoutAs(info);
}
