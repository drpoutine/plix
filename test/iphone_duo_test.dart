import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plix/services/iphone_duo_service.dart';
import 'package:plix/widgets/duo_fold.dart';

const _cover = Size(466, 678);
const _innerPortrait = Size(669, 951);
const _innerLandscape = Size(951, 669);

Map<String, dynamic> _native({
  String hinge = 'fullyOpen',
  bool inner = true,
  bool landscape = false,
  Map<String, double>? fold,
}) =>
    {
      'isDuo': true,
      'hinge': hinge,
      'angle': 1.6,
      'inner': inner,
      'landscape': landscape,
      if (fold != null) 'fold': fold,
    };

Future<void> _pump(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => DuoScope(child: child!),
    home: child,
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('state and nesting', stateTests);

  setUp(IPhoneDuoService.debugReset);
  tearDown(IPhoneDuoService.debugReset);

  group('resolvePosture', () {
    DuoPosture r(DuoHingeStatus h, {bool inner = true, bool landscape = false, bool duo = true}) =>
        IPhoneDuoInfo.resolvePosture(
            isDuo: duo, hinge: h, isInnerDisplay: inner, isLandscape: landscape);

    test('other devices are never a Duo pose', () {
      for (final h in DuoHingeStatus.values) {
        expect(r(h, duo: false), DuoPosture.none);
        expect(r(h, duo: false, landscape: true), DuoPosture.none);
      }
    });

    test('hinge and orientation table', () {
      expect(r(DuoHingeStatus.closed), DuoPosture.closed);
      expect(r(DuoHingeStatus.fullyOpen), DuoPosture.fullyOpen);
      expect(r(DuoHingeStatus.fullyOpen, landscape: true), DuoPosture.fullyOpen);
      expect(r(DuoHingeStatus.partiallyOpen), DuoPosture.tabletop);
      expect(r(DuoHingeStatus.partiallyOpen, landscape: true), DuoPosture.book);
    });

    test('no hinge reading on the inner display is flat, never folded', () {
      expect(r(DuoHingeStatus.unknown), DuoPosture.fullyOpen);
      expect(r(DuoHingeStatus.unknown, landscape: true), DuoPosture.fullyOpen);
    });

    test('outer display is always closed', () {
      for (final h in DuoHingeStatus.values) {
        expect(r(h, inner: false), DuoPosture.closed);
      }
    });
  });

  group('IPhoneDuoInfo', () {
    test('parses non-Duo and null payloads as not a Duo', () {
      expect(IPhoneDuoInfo.fromMap(null).isDuo, isFalse);
      expect(IPhoneDuoInfo.fromMap(const {'isDuo': false}).posture, DuoPosture.none);
      expect(IPhoneDuoInfo.fromMap(const {'isDuo': false}).foldFor(_innerPortrait), isNull);
    });

    test('flat and closed reserve no fold', () {
      expect(IPhoneDuoInfo.fromMap(_native()).foldFor(_innerPortrait), isNull);
      expect(IPhoneDuoInfo.fromMap(_native(hinge: 'closed', inner: false)).foldFor(_cover), isNull);
    });

    test('tabletop falls back to a 40pt band on the mid line', () {
      final info = IPhoneDuoInfo.fromMap(_native(hinge: 'partiallyOpen'));
      final fold = info.foldFor(_innerPortrait)!;
      expect(fold.axis, Axis.horizontal);
      expect(fold.band, const Rect.fromLTRB(0, 455.5, 669, 495.5));
    });

    test('book falls back to a 40pt band down the middle', () {
      final info = IPhoneDuoInfo.fromMap(_native(hinge: 'partiallyOpen', landscape: true));
      final fold = info.foldFor(_innerLandscape)!;
      expect(fold.axis, Axis.vertical);
      expect(fold.band, const Rect.fromLTRB(455.5, 0, 495.5, 669));
    });

    test('uses the reported region when it fits the pose', () {
      final info = IPhoneDuoInfo.fromMap(_native(
        hinge: 'partiallyOpen',
        fold: const {'x': 0, 'y': 450, 'width': 669, 'height': 52},
      ));
      expect(info.foldFor(_innerPortrait)!.band, const Rect.fromLTRB(0, 450, 669, 502));
    });

    test('ignores a stale region from the other orientation', () {
      final info = IPhoneDuoInfo.fromMap(_native(
        hinge: 'partiallyOpen',
        landscape: true,
        fold: const {'x': 0, 'y': 455.5, 'width': 669, 'height': 40},
      ));
      expect(info.foldFor(_innerLandscape)!.band, const Rect.fromLTRB(455.5, 0, 495.5, 669));
    });

    test('layout equality ignores the hinge angle', () {
      final a = IPhoneDuoInfo.fromMap(_native(hinge: 'partiallyOpen'));
      final b = IPhoneDuoInfo.fromMap({..._native(hinge: 'partiallyOpen'), 'angle': 2.0});
      expect(a == b, isFalse);
      expect(a.sameLayoutAs(b), isTrue);
    });
  });

  group('IPhoneDuoService', () {
    test('native updates notify listeners and the stream', () async {
      final seen = <DuoPosture>[];
      final sub = IPhoneDuoService.onPostureChanged.listen((i) => seen.add(i.posture));
      IPhoneDuoService.updateFromNative(_native(hinge: 'partiallyOpen'));
      IPhoneDuoService.updateFromNative(_native(hinge: 'partiallyOpen'));
      IPhoneDuoService.updateFromNative(_native());
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen, [DuoPosture.tabletop, DuoPosture.fullyOpen]);
    });

    test('simulation works without hardware and follows orientation', () async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      final info = IPhoneDuoService.currentInfo;
      expect(info.isDuo, isTrue);
      expect(info.postureFor(Orientation.portrait), DuoPosture.tabletop);
      expect(info.postureFor(Orientation.landscape), DuoPosture.book);
      await IPhoneDuoService.setSimulatedPosture(null);
      expect(IPhoneDuoService.isDuo, isFalse);
    });
  });

  group('platform channel', () {
    const channel = MethodChannel('com.plix.plix/duo');

    Future<void> sendFromNative(WidgetTester tester, String method, Object? arguments) {
      return tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'com.plix.plix/duo',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );
    }

    testWidgets('init() asks for getDuoInfo and then follows onDuoInfoChanged', (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'getDuoInfo') return _native(hinge: 'partiallyOpen');
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        channel.setMethodCallHandler(null);
      });

      final info = await IPhoneDuoService.init(debugIsIOS: true);
      expect(calls, ['getDuoInfo']);
      expect(info.isDuo, isTrue);
      expect(IPhoneDuoService.isInitialized, isTrue);
      expect(IPhoneDuoService.currentInfo.isDuo, isTrue);
      expect(IPhoneDuoService.currentInfo.hinge, DuoHingeStatus.partiallyOpen);
      expect(IPhoneDuoService.currentPosture, DuoPosture.tabletop);

      await sendFromNative(tester, 'onDuoInfoChanged', _native(hinge: 'partiallyOpen', landscape: true));
      expect(IPhoneDuoService.currentPosture, DuoPosture.book);

      await sendFromNative(tester, 'onDuoInfoChanged', _native(hinge: 'closed', inner: false));
      expect(IPhoneDuoService.currentInfo.hinge, DuoHingeStatus.closed);
      expect(IPhoneDuoService.currentPosture, DuoPosture.closed);

      // Other methods on the channel are ignored.
      await sendFromNative(tester, 'somethingElse', _native(hinge: 'partiallyOpen'));
      expect(IPhoneDuoService.currentPosture, DuoPosture.closed);
    });

    testWidgets('init() off iOS never touches the channel', (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return _native(hinge: 'partiallyOpen');
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

      final info = await IPhoneDuoService.init(debugIsIOS: false);
      expect(calls, isEmpty);
      expect(info.isDuo, isFalse);
    });

    testWidgets('a failing getDuoInfo leaves the device as not a Duo', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unavailable');
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        channel.setMethodCallHandler(null);
      });

      final info = await IPhoneDuoService.init(debugIsIOS: true);
      expect(info.isDuo, isFalse);
      expect(IPhoneDuoService.currentPosture, DuoPosture.none);
    });
  });

  group('anchor gating', () {
    // What an Android foldable in flex mode reports: a hinge across the middle.
    const foreignHinge = ui.DisplayFeature(
      bounds: Rect.fromLTRB(0, 455.5, 669, 495.5),
      type: ui.DisplayFeatureType.hinge,
      state: ui.DisplayFeatureState.postureHalfOpened,
    );

    // The foreign hinge sits above the Navigator, where the platform puts it,
    // so that modal routes see it too.
    Future<BuildContext> pumpReader(WidgetTester tester, Size size, {bool foreign = false}) async {
      late BuildContext ctx;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) {
          final scope = DuoScope(child: child!);
          if (!foreign) return scope;
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(displayFeatures: const [foreignHinge]),
            child: scope,
          );
        },
        home: Scaffold(body: Builder(builder: (context) {
          ctx = context;
          // Establish the dependencies production call sites have.
          IPhoneDuoService.foldOf(context);
          return const SizedBox.expand();
        })),
      ));
      await tester.pump();
      return ctx;
    }

    void expectDefaults(BuildContext ctx, String reason) {
      expect(IPhoneDuoService.sheetAnchorOf(ctx), isNull, reason: reason);
      expect(IPhoneDuoService.controlsAnchorOf(ctx), isNull, reason: reason);
      expect(IPhoneDuoService.controlsSheetHeightRatioOf(ctx), 9.0 / 16.0, reason: reason);
    }

    testWidgets('no anchor and the default height cap on a device that is not a Duo', (tester) async {
      final ctx = await pumpReader(tester, _innerPortrait);
      expectDefaults(ctx, 'not a Duo');
    });

    testWidgets('a foreign hinge DisplayFeature does not turn the anchors on', (tester) async {
      final ctx = await pumpReader(tester, _innerPortrait, foreign: true);
      expect(MediaQuery.of(ctx).displayFeatures.single.type, ui.DisplayFeatureType.hinge);
      expect(IPhoneDuoService.isDuo, isFalse);
      expectDefaults(ctx, 'foldable that is not a Duo');

      // With the null anchor Flutter keeps its own default: the sub-screen
      // that contains Offset.zero, i.e. the upper half.
      showModalBottomSheet<void>(
        context: ctx,
        anchorPoint: IPhoneDuoService.sheetAnchorOf(ctx),
        constraints: const BoxConstraints(),
        builder: (_) => const SizedBox(height: 200, width: double.infinity, key: Key('sheet')),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const Key('sheet')));
      expect(rect.left, 0);
      expect(rect.width, _innerPortrait.width);
      expect(rect.bottom, lessThanOrEqualTo(455.5));
    });

    testWidgets('no anchor on a Duo that is closed or laid flat', (tester) async {
      for (final entry in {
        DuoPosture.closed: _cover,
        DuoPosture.fullyOpen: _innerPortrait,
      }.entries) {
        await IPhoneDuoService.setSimulatedPosture(entry.key);
        final ctx = await pumpReader(tester, entry.value);
        expect(IPhoneDuoService.isDuo, isTrue);
        expectDefaults(ctx, '${entry.key}');
      }
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      final ctx = await pumpReader(tester, _innerLandscape);
      expectDefaults(ctx, 'fullyOpen landscape');
    });

    testWidgets('the anchors and the taller cap while a Duo is half folded', (tester) async {
      for (final entry in {
        DuoPosture.tabletop: _innerPortrait,
        DuoPosture.book: _innerLandscape,
      }.entries) {
        await IPhoneDuoService.setSimulatedPosture(entry.key);
        final ctx = await pumpReader(tester, entry.value);
        expect(IPhoneDuoService.postureOf(ctx), entry.key);
        expect(IPhoneDuoService.sheetAnchorOf(ctx), IPhoneDuoService.sheetAnchor, reason: '${entry.key}');
        expect(IPhoneDuoService.controlsAnchorOf(ctx), IPhoneDuoService.controlsAnchor, reason: '${entry.key}');
        expect(IPhoneDuoService.controlsSheetHeightRatioOf(ctx), 0.9, reason: '${entry.key}');
      }
    });

    testWidgets('the same reported by the hardware rather than the simulator', (tester) async {
      IPhoneDuoService.updateFromNative(_native(hinge: 'partiallyOpen'));
      final ctx = await pumpReader(tester, _innerPortrait);
      expect(IPhoneDuoService.sheetAnchorOf(ctx), IPhoneDuoService.sheetAnchor);
      expect(IPhoneDuoService.controlsAnchorOf(ctx), IPhoneDuoService.controlsAnchor);
      expect(IPhoneDuoService.controlsSheetHeightRatioOf(ctx), 0.9);

      IPhoneDuoService.updateFromNative(_native());
      await tester.pump();
      expectDefaults(ctx, 'unfolded flat');
    });
  });

  group('DuoScope', () {
    testWidgets('adds nothing on other devices', (tester) async {
      late MediaQueryData mq;
      late DuoPosture posture;
      await _pump(tester, _innerLandscape, Builder(builder: (context) {
        mq = MediaQuery.of(context);
        posture = IPhoneDuoService.postureOf(context);
        return const SizedBox();
      }));
      expect(mq.displayFeatures, isEmpty);
      expect(posture, DuoPosture.none);
    });

    testWidgets('publishes the fold only while half folded and rebuilds readers', (tester) async {
      late MediaQueryData mq;
      late DuoPosture posture;
      await _pump(tester, _innerLandscape, Builder(builder: (context) {
        mq = MediaQuery.of(context);
        posture = IPhoneDuoService.postureOf(context);
        return const SizedBox();
      }));

      IPhoneDuoService.updateFromNative(_native(landscape: true));
      await tester.pump();
      expect(posture, DuoPosture.fullyOpen);
      expect(mq.displayFeatures, isEmpty);

      IPhoneDuoService.updateFromNative(_native(hinge: 'partiallyOpen', landscape: true));
      await tester.pump();
      expect(posture, DuoPosture.book);
      expect(mq.displayFeatures.single.bounds, const Rect.fromLTRB(455.5, 0, 495.5, 669));

      IPhoneDuoService.updateFromNative(_native(hinge: 'closed', inner: false));
      await tester.pump();
      expect(posture, DuoPosture.closed);
      expect(mq.displayFeatures, isEmpty);
    });

    testWidgets('dialogs stay on one side of the spine in book', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      late BuildContext ctx;
      await _pump(tester, _innerLandscape, Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }));
      showDialog<void>(
        context: ctx,
        builder: (_) => const AlertDialog(content: SizedBox(width: 600, height: 100, key: Key('c'))),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(AlertDialog));
      expect(rect.right, lessThanOrEqualTo(455.5));
    });

    testWidgets('bottom sheets with the sheet anchor use the lower half in tabletop', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      late BuildContext ctx;
      await _pump(tester, _innerPortrait, Scaffold(body: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      })));
      showModalBottomSheet<void>(
        context: ctx,
        anchorPoint: IPhoneDuoService.sheetAnchor,
        builder: (_) => const SizedBox(height: 900, key: Key('sheet')),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const Key('sheet')));
      expect(rect.top, greaterThanOrEqualTo(495.5));
    });
  });

  group('DuoSpineGridDelegate', () {
    const base = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 160,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 2 / 3,
    );

    Widget grid() => Scaffold(
          body: DuoFoldBuilder(
            builder: (context, fold) => GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              gridDelegate: DuoSpineGridDelegate(base: base, fold: fold, crossAxisInset: 16),
              itemCount: 40,
              itemBuilder: (_, i) => Container(key: ValueKey('t$i'), color: Colors.blue),
            ),
          ),
        );

    testWidgets('matches the base layout when not folded', (tester) async {
      await _pump(tester, _innerLandscape, grid());
      final withWrapper = tester.getRect(find.byKey(const ValueKey('t3')));
      await _pump(
          tester,
          _innerLandscape,
          Scaffold(
            body: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              gridDelegate: base,
              itemCount: 40,
              itemBuilder: (_, i) => Container(key: ValueKey('t$i'), color: Colors.blue),
            ),
          ));
      expect(tester.getRect(find.byKey(const ValueKey('t3'))), withWrapper);
    });

    testWidgets('no tile touches the spine in book', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(tester, _innerLandscape, grid());
      await tester.pump();
      const band = Rect.fromLTRB(455.5, 0, 495.5, 669);
      var found = 0;
      for (var i = 0; i < 40; i++) {
        final f = find.byKey(ValueKey('t$i'));
        if (f.evaluate().isEmpty) continue;
        found++;
        final rect = tester.getRect(f);
        expect(rect.overlaps(band), isFalse, reason: 'tile $i at $rect');
        expect(rect.left, greaterThanOrEqualTo(16));
        expect(rect.right, lessThanOrEqualTo(951 - 16 + 0.01));
      }
      expect(found, greaterThan(6));
      // Aspect ratio is preserved.
      final t0 = tester.getRect(find.byKey(const ValueKey('t0')));
      expect(t0.width / t0.height, closeTo(2 / 3, 0.001));
    });

    testWidgets('tabletop leaves a vertical grid alone', (tester) async {
      await _pump(tester, _innerPortrait, grid());
      final flat = tester.getRect(find.byKey(const ValueKey('t2')));
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(find.byKey(const ValueKey('t2'))), flat);
    });
  });

  group('DuoAvoidFold', () {
    testWidgets('keeps fixed content on the chosen side of the spine', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(
        tester,
        _innerLandscape,
        Scaffold(
          body: Column(children: [
            DuoAvoidFold(child: Container(height: 50, color: Colors.red, key: const Key('lead'))),
            DuoAvoidFold(
              side: DuoFoldSide.trailing,
              child: Container(height: 50, color: Colors.green, key: const Key('trail')),
            ),
          ]),
        ),
      );
      await tester.pump();
      expect(tester.getRect(find.byKey(const Key('lead'))).right, closeTo(455.5, 0.01));
      expect(tester.getRect(find.byKey(const Key('trail'))).left, closeTo(495.5, 0.01));
    });

    testWidgets('is a pass-through when not folded', (tester) async {
      await _pump(
        tester,
        _innerLandscape,
        Scaffold(
          body: Column(children: [
            DuoAvoidFold(child: Container(height: 50, color: Colors.red, key: const Key('lead'))),
          ]),
        ),
      );
      expect(tester.getRect(find.byKey(const Key('lead'))).width, 951);
    });

    testWidgets('book: a widget starting just before the spine uses the other side', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(
        tester,
        _innerLandscape,
        const Scaffold(
          body: Row(children: [
            SizedBox(width: 440),
            Expanded(
              child: DuoAvoidFold(
                child: Row(
                  key: Key('r'),
                  children: [SizedBox(width: 100, height: 20), SizedBox(width: 100, height: 20)],
                ),
              ),
            ),
          ]),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      // 15.5pt before the spine is no use: the content goes right of it.
      final rect = tester.getRect(find.byKey(const Key('r')));
      expect(rect.left, closeTo(495.5, 0.01));
      expect(rect.right, closeTo(951, 0.01));
    });

    testWidgets('tabletop: a widget starting just above the fold uses the other side', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      await _pump(
        tester,
        _innerPortrait,
        const Scaffold(
          body: Column(children: [
            SizedBox(height: 445),
            Expanded(
              child: DuoAvoidFold(
                avoidTabletop: true,
                child: Column(
                  key: Key('c'),
                  children: [SizedBox(width: 100, height: 60), SizedBox(width: 100, height: 60)],
                ),
              ),
            ),
          ]),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byKey(const Key('c')));
      expect(rect.top, closeTo(495.5, 0.01));
      expect(rect.bottom, closeTo(951, 0.01));
    });

    testWidgets('a trailing side under 72pt falls back to the leading side', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(
        tester,
        _innerLandscape,
        Scaffold(
          body: Row(children: [
            Expanded(
              child: DuoAvoidFold(
                side: DuoFoldSide.trailing,
                child: Container(height: 20, color: Colors.red, key: const Key('box')),
              ),
            ),
            // Leaves 15.5pt right of the spine.
            const SizedBox(width: 440),
          ]),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byKey(const Key('box')));
      expect(rect.left, 0);
      expect(rect.right, closeTo(455.5, 0.01));
    });

    testWidgets('a side of 72pt or more is still honoured', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(
        tester,
        _innerLandscape,
        Scaffold(
          body: Row(children: [
            // Leaves 75.5pt left of the spine.
            const SizedBox(width: 380),
            Expanded(
              child: DuoAvoidFold(child: Container(height: 20, color: Colors.red, key: const Key('box'))),
            ),
          ]),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byKey(const Key('box')));
      expect(rect.left, 380);
      expect(rect.right, closeTo(455.5, 0.01));
    });

    testWidgets('with under 72pt on both sides the child is left untouched', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(
        tester,
        _innerLandscape,
        Scaffold(
          body: Row(children: [
            const SizedBox(width: 420),
            Expanded(
              child: DuoAvoidFold(child: Container(height: 20, color: Colors.red, key: const Key('box'))),
            ),
            const SizedBox(width: 420),
          ]),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byKey(const Key('box')));
      expect(rect.left, 420);
      expect(rect.right, 531);
    });

    testWidgets('iOS: a covered route that rebuilds keeps its fold position after the pop', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
        final tick = ValueNotifier(0);
        addTearDown(tick.dispose);
        late BuildContext ctx;
        await _pump(
          tester,
          _innerLandscape,
          Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: tick,
              builder: (context, value, _) {
                ctx = context;
                return Column(children: [
                  DuoAvoidFold(
                    child: Container(height: 50, color: Colors.red, key: const ValueKey('lead')),
                  ),
                  Text('tick $value'),
                ]);
              },
            ),
          ),
        );
        await tester.pump();
        final before = tester.getRect(find.byKey(const ValueKey('lead')));
        expect(before.left, 0);
        expect(before.right, closeTo(455.5, 0.01));

        Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('B'))));
        await tester.pumpAndSettle();
        expect(find.text('B'), findsOneWidget);

        // The covered route is shifted by the Cupertino parallax; a rebuild
        // now re-measures the DuoAvoidFold in that state.
        final home = tester.renderObject<RenderBox>(find.byKey(const ValueKey('lead'), skipOffstage: false));
        expect(home.localToGlobal(Offset.zero).dx, lessThan(-100),
            reason: 'the covered route must be translated for this test to mean anything');
        tick.value++;
        for (var i = 0; i < 3; i++) {
          await tester.pump();
        }

        Navigator.of(ctx).pop();
        await tester.pumpAndSettle();
        expect(find.text('tick 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final after = tester.getRect(find.byKey(const ValueKey('lead')));
        expect(after.right, lessThanOrEqualTo(455.5 + 0.01));
        expect(after, before);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('rotating while half folded never lays the child out from the old measurement', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      final widths = <double>[];
      // Content that something else already confines to the left half, as
      // ProfileSetupScreen does: in book the fold does not cross it.
      await _pump(
        tester,
        _innerPortrait,
        Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Builder(builder: (context) {
              final fold = IPhoneDuoService.foldOf(context);
              return SizedBox(
                width: fold != null && fold.isBook ? fold.start : null,
                child: DuoAvoidFold(
                  avoidTabletop: true,
                  child: LayoutBuilder(builder: (_, c) {
                    widths.add(c.maxWidth);
                    return const Row(
                      key: Key('form'),
                      children: [
                        SizedBox(width: 200, height: 20),
                        SizedBox(width: 200, height: 20),
                      ],
                    );
                  }),
                ),
              );
            }),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Tabletop: full width, kept above the fold.
      expect(widths.last, 669);
      expect(tester.getRect(find.byKey(const Key('form'))).bottom, lessThanOrEqualTo(455.5));

      widths.clear();
      tester.view.physicalSize = _innerLandscape;
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'frame $i after the rotation');
      }
      expect(IPhoneDuoService.postureOf(tester.element(find.byKey(const Key('form')))), DuoPosture.book);
      expect(widths, isNotEmpty);
      // Never squeezed below the confined half, not even for one frame.
      expect(widths.reduce((a, b) => a < b ? a : b), closeTo(455.5, 0.01));
      final rect = tester.getRect(find.byKey(const Key('form')));
      expect(rect.left, 0);
      expect(rect.right, closeTo(455.5, 0.01));
    });
  });
}

// Appended: state preservation and nesting.
class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  static int created = 0;
  @override
  void initState() {
    super.initState();
    created++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 20);
}

void stateTests() {
  setUp(IPhoneDuoService.debugReset);
  tearDown(IPhoneDuoService.debugReset);

  testWidgets('folding and unfolding keeps the State below DuoAvoidFold and DuoFoldBuilder', (tester) async {
    _CounterState.created = 0;
    await _pump(
      tester,
      _innerLandscape,
      Scaffold(
        body: Column(children: [
          const DuoAvoidFold(child: _Counter()),
          Expanded(child: DuoFoldBuilder(builder: (_, __) => const _Counter())),
        ]),
      ),
    );
    expect(_CounterState.created, 2);
    await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
    await tester.pump();
    await tester.pump();
    expect(_CounterState.created, 2);
  });

  testWidgets('a nested DuoAvoidFold does not pad a second time', (tester) async {
    final widths = <double>[];
    await _pump(
      tester,
      _innerLandscape,
      Scaffold(
        body: Column(children: [
          DuoAvoidFold(
            child: Column(children: [
              DuoAvoidFold(
                child: LayoutBuilder(builder: (_, c) {
                  widths.add(c.maxWidth);
                  return Container(height: 40, color: Colors.red, key: const Key('inner'));
                }),
              ),
            ]),
          ),
        ]),
      ),
    );
    expect(widths.last, 951);
    await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
    // Never squeezed below the confined half, not even for one frame.
    expect(widths.reduce((a, b) => a < b ? a : b), closeTo(455.5, 0.01));
    final rect = tester.getRect(find.byKey(const Key('inner')));
    expect(rect.left, 0);
    expect(rect.right, closeTo(455.5, 0.01));
  });

  testWidgets('tabletop pass-through does not stretch a title', (tester) async {
    await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
    await _pump(
      tester,
      _innerPortrait,
      Scaffold(appBar: AppBar(title: const DuoAvoidFold(child: Text('Movies', key: Key('t'))))),
    );
    await tester.pump();
    expect(tester.getRect(find.byKey(const Key('t'))).height, lessThan(40));
  });
}
