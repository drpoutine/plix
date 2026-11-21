import 'package:flutter/material.dart';
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
      expect(IPhoneDuoInfo.fromMap({'isDuo': false}).posture, DuoPosture.none);
      expect(IPhoneDuoInfo.fromMap({'isDuo': false}).foldFor(_innerPortrait), isNull);
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
  });
}
