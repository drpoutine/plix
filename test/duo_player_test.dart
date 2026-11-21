import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plix/screens/player_screen.dart';
import 'package:plix/services/iphone_duo_service.dart';
import 'package:plix/widgets/duo_fold.dart';

const _cover = Size(466, 678);
const _innerPortrait = Size(669, 951);
const _innerLandscape = Size(951, 669);

const _portraitInsets = EdgeInsets.only(top: 47, bottom: 34);
const _landscapeInsets = EdgeInsets.only(left: 10, right: 10, bottom: 21);

DuoFold _fold(Size size, {Rect? reported}) {
  final info = IPhoneDuoInfo(
    isDuo: true,
    hinge: DuoHingeStatus.partiallyOpen,
    isInnerDisplay: true,
    foldRect: reported,
  );
  return info.foldFor(size)!;
}

void _expectSound(DuoPlayerGeometry g, Size size, DuoFold fold, EdgeInsets padding) {
  final safe = Rect.fromLTRB(
    padding.left,
    padding.top,
    size.width - padding.right,
    size.height - padding.bottom,
  );
  final blocks = {'topBar': g.topBar, 'picture': g.picture, 'controls': g.controls};

  blocks.forEach((name, rect) {
    expect(rect.width, greaterThan(0), reason: '$name has no width');
    expect(rect.height, greaterThan(0), reason: '$name has no height');
    expect(rect.overlaps(fold.band), isFalse, reason: '$name overlaps the fold band');
    expect(rect.left, greaterThanOrEqualTo(safe.left - 0.01), reason: '$name left');
    expect(rect.top, greaterThanOrEqualTo(safe.top - 0.01), reason: '$name top');
    expect(rect.right, lessThanOrEqualTo(safe.right + 0.01), reason: '$name right');
    expect(rect.bottom, lessThanOrEqualTo(safe.bottom + 0.01), reason: '$name bottom');
  });

  expect(g.topBar.overlaps(g.picture), isFalse);
  expect(g.topBar.overlaps(g.controls), isFalse);
  expect(g.picture.overlaps(g.controls), isFalse);

  expect(g.picture.width / g.picture.height, closeTo(16 / 9, 0.001));
  expect(g.topBar.height, DuoPlayerGeometry.barHeight);

  if (fold.isTabletop) {
    expect(g.topBar.bottom, lessThanOrEqualTo(g.picture.top));
    expect(g.picture.bottom, lessThanOrEqualTo(fold.start - DuoPlayerGeometry.foldGap + 0.01));
    expect(g.controls.top, greaterThanOrEqualTo(fold.end + DuoPlayerGeometry.foldGap - 0.01));
    expect((g.picture.center.dx - safe.center.dx).abs(), lessThan(0.01));
  } else {
    expect(g.picture.right, lessThanOrEqualTo(fold.start - DuoPlayerGeometry.foldGap + 0.01));
    expect(g.topBar.left, greaterThanOrEqualTo(fold.end + DuoPlayerGeometry.foldGap - 0.01));
    expect(g.controls.left, greaterThanOrEqualTo(fold.end + DuoPlayerGeometry.foldGap - 0.01));
    expect((g.picture.center.dy - safe.center.dy).abs(), lessThan(0.01));
  }

  // The fixed transport block always fits without scrolling.
  expect(g.controls.height, greaterThanOrEqualTo(DuoPlayerControls.height));
}

class _Probe extends StatefulWidget {
  const _Probe({super.key});

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blueGrey);
}

Widget _controls({bool episode = true}) {
  return DuoPlayerControls(
    positionLabel: '1:02:03',
    durationLabel: '2:14:59',
    value: 30,
    max: 100,
    onScrubStart: (_) {},
    onScrubUpdate: (_) {},
    onScrubEnd: (_) {},
    isPlaying: true,
    onPlayPause: () {},
    rewindSeconds: 10,
    forwardSeconds: 30,
    onRewind: () {},
    onForward: () {},
    previousTitle: episode ? 'Previous' : null,
    onPrevious: episode ? () {} : null,
    nextTitle: episode ? 'Next' : null,
    onNext: episode ? () {} : null,
    options: [
      DuoPlayerOption(
        icon: Icons.audiotrack_rounded,
        label: 'English (TrueHD 7.1 Atmos) Commentary',
        onPressed: () {},
      ),
      DuoPlayerOption(
        icon: Icons.subtitles_rounded,
        label: 'English (SDH, Forced) PGS',
        isHighlight: true,
        onPressed: () {},
      ),
      DuoPlayerOption(icon: Icons.tune_rounded, label: 'Original', onPressed: () {}),
      DuoPlayerOption(icon: Icons.speed_rounded, label: '1.25x', onPressed: () {}),
    ],
  );
}

Widget _layout() {
  return Scaffold(
    backgroundColor: Colors.transparent,
    body: DuoPlayerLayout(
      backgroundColor: Colors.black,
      topBar: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back), onPressed: () {}),
          IconButton(icon: const Icon(Icons.home_rounded), onPressed: () {}),
          const Expanded(
            child: Text('A fairly long episode title that has to be cut off', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          IconButton(icon: const Icon(Icons.screen_rotation_rounded), onPressed: () {}),
          IconButton(icon: const Icon(Icons.picture_in_picture_alt_rounded), onPressed: () {}),
        ],
      ),
      picture: const _Probe(key: ValueKey('picture')),
      controls: LayoutBuilder(
        key: const ValueKey('controls'),
        builder: (context, constraints) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _controls(),
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < 12; i++) ListTile(title: Text('Episode $i'), onTap: () {}),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Size size,
  Widget home, {
  EdgeInsets insets = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding(
    left: insets.left,
    top: insets.top,
    right: insets.right,
    bottom: insets.bottom,
  );
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => DuoScope(child: child!),
    home: home,
  ));
  await tester.pump();
}

/// Everything a finger can hit in the pumped layout.
Iterable<Rect> _tapTargets(WidgetTester tester) sync* {
  for (final finder in [
    find.byType(IconButton),
    find.byType(InkWell),
    find.byType(Slider),
    find.byType(GestureDetector),
  ]) {
    for (final element in finder.evaluate()) {
      final box = element.renderObject;
      if (box is RenderBox && box.hasSize && box.attached) {
        yield box.localToGlobal(Offset.zero) & box.size;
      }
    }
  }
}

void main() {
  setUp(IPhoneDuoService.debugReset);
  tearDown(IPhoneDuoService.debugReset);

  group('DuoPlayerGeometry', () {
    test('tabletop at 669x951: picture above the fold, controls below it', () {
      final fold = _fold(_innerPortrait);
      expect(fold.isTabletop, isTrue);

      final bare = DuoPlayerGeometry.compute(size: _innerPortrait, fold: fold);
      _expectSound(bare, _innerPortrait, fold, EdgeInsets.zero);
      // Full width (minus the inset) fits when nothing is reserved on top.
      expect(bare.picture.width, closeTo(_innerPortrait.width - 2 * DuoPlayerGeometry.pictureInset, 0.01));

      final g = DuoPlayerGeometry.compute(size: _innerPortrait, fold: fold, padding: _portraitInsets);
      _expectSound(g, _innerPortrait, fold, _portraitInsets);
      expect(g.topBar.top, _portraitInsets.top);
      // With the status bar, 16:9 at full width is too tall: the box shrinks
      // and stays centred.
      expect(g.picture.width, lessThan(bare.picture.width));
      expect(g.picture.bottom, closeTo(fold.start - DuoPlayerGeometry.foldGap, 0.01));
      expect(g.controls.bottom, _innerPortrait.height - _portraitInsets.bottom);
    });

    test('tabletop follows a reported 52pt band that is off centre', () {
      final fold = _fold(_innerPortrait, reported: const Rect.fromLTWH(0, 440, 669, 52));
      expect(fold.band, const Rect.fromLTWH(0, 440, 669, 52));

      final g = DuoPlayerGeometry.compute(size: _innerPortrait, fold: fold, padding: _portraitInsets);
      _expectSound(g, _innerPortrait, fold, _portraitInsets);
      expect(g.picture.bottom, lessThanOrEqualTo(440 - DuoPlayerGeometry.foldGap + 0.01));
      expect(g.controls.top, closeTo(492 + DuoPlayerGeometry.foldGap, 0.01));
    });

    test('book at 951x669: picture left of the spine, controls right of it', () {
      final fold = _fold(_innerLandscape);
      expect(fold.isBook, isTrue);

      final bare = DuoPlayerGeometry.compute(size: _innerLandscape, fold: fold);
      _expectSound(bare, _innerLandscape, fold, EdgeInsets.zero);

      final g = DuoPlayerGeometry.compute(size: _innerLandscape, fold: fold, padding: _landscapeInsets);
      _expectSound(g, _innerLandscape, fold, _landscapeInsets);
      expect(g.picture.left, closeTo(_landscapeInsets.left + DuoPlayerGeometry.pictureInset, 0.01));
      expect(g.picture.right, closeTo(fold.start - DuoPlayerGeometry.foldGap, 0.01));
      expect(g.topBar.bottom, g.controls.top);
      expect(g.controls.right, _innerLandscape.width - _landscapeInsets.right);
    });

    test('book follows a reported 52pt band that is off centre', () {
      final fold = _fold(_innerLandscape, reported: const Rect.fromLTWH(430, 0, 52, 669));
      expect(fold.band, const Rect.fromLTWH(430, 0, 52, 669));

      final g = DuoPlayerGeometry.compute(size: _innerLandscape, fold: fold, padding: _landscapeInsets);
      _expectSound(g, _innerLandscape, fold, _landscapeInsets);
      expect(g.picture.right, closeTo(430 - DuoPlayerGeometry.foldGap, 0.01));
      expect(g.controls.left, closeTo(482 + DuoPlayerGeometry.foldGap, 0.01));
    });

    test('never produces a negative rect when the view is too small', () {
      const size = Size(120, 90);
      final g = DuoPlayerGeometry.compute(
        size: size,
        fold: _fold(size),
        padding: const EdgeInsets.all(40),
      );
      for (final rect in [g.topBar, g.picture, g.controls]) {
        expect(rect.width, greaterThanOrEqualTo(0));
        expect(rect.height, greaterThanOrEqualTo(0));
      }
    });
  });

  group('DuoPlayerLayout', () {
    Future<void> expectClearOfFold(WidgetTester tester, Size size, EdgeInsets insets) async {
      final context = tester.element(find.byType(DuoPlayerLayout));
      final fold = IPhoneDuoService.foldOf(context)!;
      final expected = DuoPlayerGeometry.compute(size: size, fold: fold, padding: insets);

      expect(tester.getRect(find.byKey(const ValueKey('picture'))), expected.picture);
      expect(tester.getRect(find.byKey(const ValueKey('controls'))), expected.controls);

      final targets = _tapTargets(tester).toList();
      expect(targets.length, greaterThan(10));
      for (final rect in targets) {
        expect(rect.overlaps(fold.band), isFalse, reason: 'tap target $rect is in the fold $fold');
        expect(rect.left, greaterThanOrEqualTo(-0.01));
        expect(rect.right, lessThanOrEqualTo(size.width + 0.01));
      }
      expect(tester.takeException(), isNull);
    }

    testWidgets('tabletop keeps every tap target out of the band', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      await _pump(tester, _innerPortrait, _layout(), insets: _portraitInsets);
      await expectClearOfFold(tester, _innerPortrait, _portraitInsets);

      final fold = IPhoneDuoService.foldOf(tester.element(find.byType(DuoPlayerLayout)))!;
      expect(tester.getRect(find.byKey(const ValueKey('picture'))).bottom, lessThan(fold.start));
      final inControls = find.descendant(
        of: find.byKey(const ValueKey('controls')),
        matching: find.byWidgetPredicate((w) => w is Slider || w is InkWell || w is IconButton),
      );
      expect(inControls, findsWidgets);
      for (final finder in [inControls, find.byType(Slider)]) {
        for (final element in finder.evaluate()) {
          final box = element.renderObject! as RenderBox;
          expect(box.localToGlobal(Offset.zero).dy, greaterThan(fold.end));
        }
      }
    });

    testWidgets('book keeps every tap target out of the band', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(tester, _innerLandscape, _layout(), insets: _landscapeInsets);
      await expectClearOfFold(tester, _innerLandscape, _landscapeInsets);

      final fold = IPhoneDuoService.foldOf(tester.element(find.byType(DuoPlayerLayout)))!;
      expect(tester.getRect(find.byKey(const ValueKey('picture'))).right, lessThan(fold.start));
      for (final finder in [find.byType(IconButton), find.byType(Slider), find.byType(InkWell)]) {
        for (final element in finder.evaluate()) {
          final box = element.renderObject! as RenderBox;
          expect(box.localToGlobal(Offset.zero).dx, greaterThan(fold.end));
        }
      }
    });

    testWidgets('uses the band the hardware reports', (tester) async {
      IPhoneDuoService.updateFromNative({
        'isDuo': true,
        'hinge': 'partiallyOpen',
        'angle': 1.6,
        'inner': true,
        'landscape': false,
        'fold': {'x': 0.0, 'y': 440.0, 'width': 669.0, 'height': 52.0},
      });
      await _pump(tester, _innerPortrait, _layout(), insets: _portraitInsets);

      final fold = IPhoneDuoService.foldOf(tester.element(find.byType(DuoPlayerLayout)))!;
      expect(fold.band, const Rect.fromLTWH(0, 440, 669, 52));
      await expectClearOfFold(tester, _innerPortrait, _portraitInsets);
    });

    testWidgets('rotating between tabletop and book keeps the picture mounted', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      await _pump(tester, _innerPortrait, _layout(), insets: _portraitInsets);
      final state = tester.state(find.byType(_Probe));
      final tabletopRect = tester.getRect(find.byType(_Probe));

      tester.view.physicalSize = _innerLandscape;
      tester.view.padding = const FakeViewPadding(bottom: 21);
      await tester.pump();
      await tester.pump();

      expect(tester.state(find.byType(_Probe)), same(state));
      final bookRect = tester.getRect(find.byType(_Probe));
      expect(bookRect, isNot(tabletopRect));
      final fold = IPhoneDuoService.foldOf(tester.element(find.byType(DuoPlayerLayout)))!;
      expect(fold.isBook, isTrue);
      expect(bookRect.right, lessThan(fold.start));
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out without overflow when the fold reserves nothing', (tester) async {
      for (final entry in {
        DuoPosture.closed: _cover,
        DuoPosture.fullyOpen: _innerPortrait,
      }.entries) {
        await IPhoneDuoService.setSimulatedPosture(entry.key);
        await _pump(tester, entry.value, _layout(), insets: _portraitInsets);
        expect(IPhoneDuoService.foldOf(tester.element(find.byType(DuoPlayerLayout))), isNull);
        expect(tester.takeException(), isNull, reason: '${entry.key}');
      }

      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(tester, _innerLandscape, _layout(), insets: _landscapeInsets);
      expect(tester.takeException(), isNull);
    });
  });

  group('DuoPlayerControls', () {
    Future<void> pumpAt(WidgetTester tester, double width, {bool episode = true}) async {
      await _pump(
        tester,
        _innerLandscape,
        Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: _controls(episode: episode)),
          ),
        ),
      );
    }

    testWidgets('fits the book half, the tabletop half and the cover width', (tester) async {
      final book = DuoPlayerGeometry.compute(
        size: _innerLandscape,
        fold: _fold(_innerLandscape, reported: const Rect.fromLTWH(430, 0, 52, 669)),
        padding: _landscapeInsets,
      );
      for (final width in [book.controls.width, _innerPortrait.width, _cover.width, 300.0]) {
        await pumpAt(tester, width);
        expect(tester.takeException(), isNull, reason: 'overflow at $width');
        expect(tester.getSize(find.byType(DuoPlayerControls)), Size(width, DuoPlayerControls.height));
        for (final element in find.byType(InkWell).evaluate()) {
          final box = element.renderObject! as RenderBox;
          final rect = box.localToGlobal(Offset.zero) & box.size;
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width + 0.01), reason: 'option button clipped at $width');
        }
      }
    });

    testWidgets('offers previous / next only for episodes and reports taps', (tester) async {
      await pumpAt(tester, 440);
      expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
      expect(find.byType(InkWell), findsNWidgets(4 + 4));

      await pumpAt(tester, 440, episode: false);
      expect(find.byIcon(Icons.skip_previous_rounded), findsNothing);
      expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    });
  });

  group('player sheets and dialogs', () {
    Widget host() {
      return Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: Column(
              children: [
                TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    anchorPoint: IPhoneDuoService.controlsAnchor,
                    scrollControlDisabledMaxHeightRatio:
                        IPhoneDuoService.foldOf(context) != null ? 0.9 : 9.0 / 16.0,
                    constraints: const BoxConstraints(),
                    builder: (_) => ListView(
                      key: const ValueKey('sheet'),
                      children: [for (var i = 0; i < 30; i++) ListTile(title: Text('Option $i'))],
                    ),
                  ),
                  child: const Text('sheet'),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    anchorPoint: IPhoneDuoService.controlsAnchor,
                    builder: (_) => const AlertDialog(
                      key: ValueKey('dialog'),
                      title: Text('Subtitles'),
                      content: Text('Search'),
                    ),
                  ),
                  child: const Text('dialog'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('open on the lower half in tabletop, never over the picture', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      await _pump(tester, _innerPortrait, host());
      final fold = IPhoneDuoService.foldOf(tester.element(find.text('sheet')))!;

      await tester.tap(find.text('sheet'));
      await tester.pumpAndSettle();
      final sheet = tester.getRect(find.byKey(const ValueKey('sheet')));
      expect(sheet.top, greaterThanOrEqualTo(fold.end));
      expect(sheet.bottom, lessThanOrEqualTo(_innerPortrait.height));
      // Most of the half, not the default 9/16 of it.
      expect(sheet.height, greaterThan((_innerPortrait.height - fold.end) * 0.8));
      Navigator.of(tester.element(find.byKey(const ValueKey('sheet')))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      final dialog = tester.getRect(find.byKey(const ValueKey('dialog')));
      expect(dialog.top, greaterThanOrEqualTo(fold.end));
      expect(tester.takeException(), isNull);
    });

    testWidgets('open on the right half in book', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(tester, _innerLandscape, host());
      final fold = IPhoneDuoService.foldOf(tester.element(find.text('sheet')))!;

      await tester.tap(find.text('sheet'));
      await tester.pumpAndSettle();
      final sheet = tester.getRect(find.byKey(const ValueKey('sheet')));
      expect(sheet.left, greaterThanOrEqualTo(fold.end));
      expect(sheet.right, lessThanOrEqualTo(_innerLandscape.width));
      Navigator.of(tester.element(find.byKey(const ValueKey('sheet')))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      final dialog = tester.getRect(find.byKey(const ValueKey('dialog')));
      expect(dialog.left, greaterThanOrEqualTo(fold.end));
      expect(tester.takeException(), isNull);
    });

    testWidgets('are unchanged when flat: full width, default height cap', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(tester, _innerPortrait, host());

      await tester.tap(find.text('sheet'));
      await tester.pumpAndSettle();
      final sheet = tester.getRect(find.byKey(const ValueKey('sheet')));
      expect(sheet.left, 0);
      expect(sheet.width, _innerPortrait.width);
      expect(sheet.bottom, _innerPortrait.height);
      expect(sheet.height, closeTo(_innerPortrait.height * 9.0 / 16.0, 0.01));
    });
  });
}
