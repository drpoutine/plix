import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plix/app_theme.dart';
import 'package:plix/screens/appearance_screen.dart';
import 'package:plix/screens/settings_screen.dart';
import 'package:plix/services/iphone_duo_service.dart';
import 'package:plix/services/plix_device_helper.dart';
import 'package:plix/services/profile_service.dart';
import 'package:plix/widgets/appearance_hero_tile.dart';
import 'package:plix/widgets/duo_fold.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _cover = Size(466, 678);
const _innerPortrait = Size(669, 951);
const _innerLandscape = Size(951, 669);

// The default test font is far wider than any real one, which would make the
// overflow checks meaningless. Roboto is the app's own font family.
Future<void> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  expect(root, isNotNull, reason: 'flutter test sets FLUTTER_ROOT');
  final loader = FontLoader('Roboto');
  for (final face in ['Regular', 'Medium', 'Bold']) {
    final file = File('$root/bin/cache/artifacts/material_fonts/Roboto-$face.ttf');
    loader.addFont(file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
  }
  await loader.load();
}

Rect _band(Size size) => IPhoneDuoService.currentInfo.foldFor(size)!.band;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(WidgetTester tester, Size size, Widget home) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: PlixTheme.themeData,
    builder: (context, child) => DuoScope(child: child!),
    home: home,
  ));
  await _settle(tester);
}

/// Every laid-out widget matched by [finder] that is on screen at all.
List<Rect> _visibleRects(WidgetTester tester, Finder finder, Size screen) {
  final view = Offset.zero & screen;
  return [
    for (final element in finder.evaluate())
      if (element.renderObject case final RenderBox box when box.hasSize && box.attached)
        box.localToGlobal(Offset.zero) & box.size,
  ].where((r) => !r.isEmpty && r.overlaps(view)).toList();
}

/// Where the glyphs of every visible [Text] actually are, which can be much
/// narrower than a text widget that expands to fill its row.
List<Rect> _visibleGlyphs(WidgetTester tester, Type screen, Size size) {
  final view = Offset.zero & size;
  final rects = <Rect>[];
  final finder = find.descendant(of: find.byType(screen), matching: find.byType(RichText));
  for (final element in finder.evaluate()) {
    final box = element.renderObject;
    if (box is! RenderParagraph || !box.hasSize || !box.attached) continue;
    final length = box.text.toPlainText().length;
    final origin = box.localToGlobal(Offset.zero);
    for (final b in box.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length))) {
      final r = b.toRect().shift(origin);
      if (!r.isEmpty && r.overlaps(view)) rects.add(r);
    }
  }
  return rects;
}

void _expectClearOf(Rect band, List<Rect> rects, String what) {
  expect(rects, isNotEmpty, reason: 'no $what found');
  for (final r in rects) {
    expect(r.overlaps(band), isFalse, reason: '$what at $r sits in the fold $band');
  }
}

Finder _within(Type screen, Type type) =>
    find.descendant(of: find.byType(screen), matching: find.byType(type));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadRoboto();
    // Until this runs PlixDeviceHelper reports a television, and the screens
    // would be built in their TV variant instead of what a Duo shows.
    await PlixDeviceHelper.initDeviceName();
    expect(PlixDeviceHelper.isTelevision, isFalse, reason: 'the test host must not be treated as a TV');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProfileService.targetProfileIdOverride = null;
    PlixTheme.resetToDefaultModern();
    IPhoneDuoService.debugReset();
  });
  tearDown(() {
    PlixTheme.resetToDefaultModern();
    IPhoneDuoService.debugReset();
  });

  group('Duo posture simulator row', () {
    Future<void> showRow(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        find.text('iPhone Duo posture'),
        400,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      );
      await _settle(tester);
    }

    testWidgets('is offered in debug builds and cycles the simulated posture', (tester) async {
      await _pump(tester, const Size(1280, 800), const SettingsScreen(clientId: 'test-client'));
      await showRow(tester);

      expect(find.text('Developer'), findsOneWidget);
      expect(find.textContaining('not the screen size'), findsOneWidget);
      expect(IPhoneDuoService.simulatedPosture, isNull);
      expect(find.text('Off'), findsOneWidget);

      Future<void> tapRow() async {
        await showRow(tester);
        await tester.tap(find.text('iPhone Duo posture'));
        await _settle(tester);
      }

      await tapRow();
      expect(IPhoneDuoService.simulatedPosture, DuoPosture.closed);
      expect(find.text('Closed'), findsOneWidget);

      await tapRow();
      expect(IPhoneDuoService.simulatedPosture, DuoPosture.fullyOpen);
      expect(find.text('Open flat'), findsOneWidget);

      await tapRow();
      expect(IPhoneDuoService.simulatedPosture, DuoPosture.tabletop);
      expect(find.text('Half folded'), findsOneWidget);
      // 1280x800 is landscape, so the half fold resolves to book.
      expect(IPhoneDuoService.currentInfo.postureFor(Orientation.landscape), DuoPosture.book);

      await tapRow();
      expect(IPhoneDuoService.simulatedPosture, isNull);
      expect(find.text('Off'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reflects a posture set elsewhere', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(tester, _innerPortrait, const SettingsScreen(clientId: 'test-client'));
      await showRow(tester);
      expect(find.text('Open flat'), findsOneWidget);
    });

    testWidgets('is reachable with the remote from the row above', (tester) async {
      await _pump(tester, const Size(1280, 800), const SettingsScreen(clientId: 'test-client'));
      await showRow(tester);
      // The row's own focus node, not the inert one inside its InkWell.
      FocusNode rowNode(String title) => tester
          .widget<Focus>(find
              .ancestor(
                of: find.text(title),
                matching: find.byWidgetPredicate((w) => w is Focus && w.onKeyEvent != null),
              )
              .first)
          .focusNode!;
      final website = rowNode('Official Website');
      website.requestFocus();
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      expect(rowNode('iPhone Duo posture').hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(IPhoneDuoService.simulatedPosture, DuoPosture.closed);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await _settle(tester);
      expect(website.hasPrimaryFocus, isTrue);
    });
  });

  group('Settings screen', () {
    for (final (size, posture) in [
      (_cover, DuoPosture.closed),
      (_innerPortrait, DuoPosture.fullyOpen),
      (_innerLandscape, DuoPosture.fullyOpen),
      (_innerPortrait, DuoPosture.tabletop),
      (_innerLandscape, DuoPosture.book),
    ]) {
      testWidgets('does not overflow at $size ($posture)', (tester) async {
        await IPhoneDuoService.setSimulatedPosture(posture);
        await _pump(tester, size, const SettingsScreen(clientId: 'test-client'));
        expect(tester.takeException(), isNull);
        final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable));
        for (var i = 0; i < 8; i++) {
          await tester.drag(list, const Offset(0, -400));
          await _settle(tester);
          expect(tester.takeException(), isNull);
        }
      });
    }

    testWidgets('book: rows and labels stay on the leading half', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(tester, _innerLandscape, const SettingsScreen(clientId: 'test-client'));
      final band = _band(_innerLandscape);
      final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable));

      for (var i = 0; i < 8; i++) {
        final rows = _visibleRects(tester, _within(SettingsScreen, InkWell), _innerLandscape);
        _expectClearOf(band, rows, 'settings row');
        _expectClearOf(band, _visibleGlyphs(tester, SettingsScreen, _innerLandscape), 'text');
        for (final r in rows) {
          expect(r.right, lessThanOrEqualTo(band.left));
        }
        await tester.drag(list, const Offset(0, -400));
        await _settle(tester);
      }
      // The list still scrolls from the far half.
      expect(tester.getSize(find.byType(ListView)).width, _innerLandscape.width);
    });

    testWidgets('book: the toast stays off the spine', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(tester, _innerLandscape, const SettingsScreen(clientId: 'test-client'));
      await tester.scrollUntilVisible(
        find.text('Check for Updates'),
        300,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      );
      await _settle(tester);
      await tester.tap(find.text('Check for Updates'));
      await _settle(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      final toast = tester.getRect(
          find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first);
      expect(toast.overlaps(_band(_innerLandscape)), isFalse, reason: 'toast $toast');
      expect(toast.width, greaterThan(200));
      await tester.pump(const Duration(seconds: 30));
      await _settle(tester);
    });

    testWidgets('lays out as before when not half folded', (tester) async {
      Future<List<Rect>> rowsAt(Size size, DuoPosture? posture) async {
        await IPhoneDuoService.setSimulatedPosture(posture);
        await _pump(tester, size, SettingsScreen(key: UniqueKey(), clientId: 'test-client'));
        return _visibleRects(tester, _within(SettingsScreen, InkWell), size);
      }

      for (final size in [_innerLandscape, _innerPortrait, _cover]) {
        final plain = await rowsAt(size, null);
        final inset = size.width > size.height ? 32.0 : 16.0;
        final rows = plain.where((r) => r.width > 300).toList();
        expect(rows, isNotEmpty);
        for (final r in rows) {
          expect(r.left, inset);
          expect(r.right, size.width - inset);
        }
        expect(await rowsAt(size, DuoPosture.fullyOpen), plain);
        expect(await rowsAt(size, DuoPosture.closed), plain);
      }
      // Tabletop only reserves a horizontal band; rows keep their width.
      final plain = await rowsAt(_innerPortrait, null);
      expect(await rowsAt(_innerPortrait, DuoPosture.tabletop), plain);
    });
  });

  group('Appearance screen', () {
    ThemePresetOption custom() => PlixTheme.presetOptions.firstWhere((p) => p.id == 'custom');

    for (final (size, posture) in [
      (_cover, DuoPosture.closed),
      (_innerPortrait, DuoPosture.fullyOpen),
      (_innerLandscape, DuoPosture.fullyOpen),
      (_innerPortrait, DuoPosture.tabletop),
      (_innerLandscape, DuoPosture.book),
    ]) {
      testWidgets('does not overflow at $size ($posture)', (tester) async {
        await IPhoneDuoService.setSimulatedPosture(posture);
        await _pump(tester, size, const AppearanceScreen());
        expect(tester.takeException(), isNull);
        expect(find.text('Appearance & Themes'), findsOneWidget);

        // The custom preset adds the "Edit Custom Palette" button to the top bar.
        PlixTheme.currentPreset.value = custom();
        await _pump(tester, size, AppearanceScreen(key: UniqueKey()));
        expect(find.text('Edit Custom Palette'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('book: tiles, labels and the preview skip the spine', (tester) async {
      PlixTheme.currentPreset.value = custom();
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(tester, _innerLandscape, const AppearanceScreen());
      final band = _band(_innerLandscape);
      final scroller = find.byType(SingleChildScrollView).first;

      for (var i = 0; i < 3; i++) {
        final tiles = _visibleRects(tester, _within(AppearanceScreen, InkWell), _innerLandscape);
        _expectClearOf(band, tiles, 'tile');
        _expectClearOf(band, _visibleGlyphs(tester, AppearanceScreen, _innerLandscape), 'text');
        // Both halves are used: nothing was simply dropped from one side.
        expect(tiles.any((r) => r.right <= band.left), isTrue);
        expect(tiles.any((r) => r.left >= band.right), isTrue);
        await tester.drag(scroller, const Offset(0, -200));
        await _settle(tester);
      }

      await tester.drag(scroller, const Offset(0, 1000));
      await _settle(tester);
      expect(tester.getRect(find.text('Live Preview')).right, lessThan(band.left));
      expect(tester.getRect(find.text('Details')).right, lessThan(band.left));
      expect(tester.getRect(find.text('Edit Custom Palette')).left, greaterThan(band.right));
      // Every preset and accent is still there.
      for (final preset in PlixTheme.presetOptions) {
        expect(find.text(preset.name), findsWidgets);
      }
      for (final option in PlixTheme.colorOptions) {
        expect(find.text(option.name), findsWidgets);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out as before when not half folded', (tester) async {
      Future<List<Rect>> tilesAt(Size size, DuoPosture? posture) async {
        await IPhoneDuoService.setSimulatedPosture(posture);
        await _pump(tester, size, AppearanceScreen(key: UniqueKey()));
        return _visibleRects(tester, _within(AppearanceScreen, InkWell), size);
      }

      for (final size in [_innerLandscape, _innerPortrait, _cover]) {
        final plain = await tilesAt(size, null);
        expect(plain.length, greaterThan(8));
        expect(await tilesAt(size, DuoPosture.fullyOpen), plain);
        expect(await tilesAt(size, DuoPosture.closed), plain);
      }
      final plain = await tilesAt(_innerPortrait, null);
      expect(await tilesAt(_innerPortrait, DuoPosture.tabletop), plain);

      // Landscape without a fold: four preset tiles with the regular 8pt gaps.
      await tilesAt(_innerLandscape, null);
      final presets = PlixTheme.presetOptions.take(4).map((p) {
        return tester.getRect(
            find.ancestor(of: find.text(p.name), matching: find.byType(InkWell)).first);
      }).toList();
      for (var i = 1; i < presets.length; i++) {
        expect(presets[i].left - presets[i - 1].right, moreOrLessEquals(8));
        expect(presets[i].width, moreOrLessEquals(presets[0].width));
      }
    });

    for (final (size, posture) in [
      (_innerPortrait, DuoPosture.tabletop),
      (_innerLandscape, DuoPosture.book),
      (_innerLandscape, DuoPosture.fullyOpen),
      (_cover, DuoPosture.closed),
    ]) {
      testWidgets('dialogs fit beside the fold at $size ($posture)', (tester) async {
        await IPhoneDuoService.setSimulatedPosture(posture);
        await _pump(tester, size, const AppearanceScreen());
        final fold = IPhoneDuoService.currentInfo.foldFor(size);
        final screen = Offset.zero & size;

        void expectDialogPlaced() {
          expect(tester.takeException(), isNull);
          final dialog = tester.getRect(
              find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first);
          expect(screen.contains(dialog.topLeft) && screen.contains(dialog.bottomRight), isTrue,
              reason: 'dialog $dialog leaves the screen');
          if (fold == null) return;
          expect(dialog.overlaps(fold.band), isFalse, reason: 'dialog $dialog crosses ${fold.band}');
          if (fold.isTabletop) {
            // Controls belong on the stable lower half.
            expect(dialog.top, greaterThanOrEqualTo(fold.band.bottom));
          } else {
            expect(dialog.right, lessThanOrEqualTo(fold.band.left));
          }
        }

        // Custom palette editor.
        final customTile = find.text(custom().name);
        await tester.ensureVisible(customTile);
        await _settle(tester);
        await tester.tap(customTile);
        await _settle(tester);
        expect(find.text('Customize Atmosphere Colors'), findsOneWidget);
        expectDialogPlaced();

        // All four rows and Done stay reachable, by scrolling when folded.
        for (final label in ['Background', 'Sidebar & Surfaces', 'Cards & Containers', 'Card Borders']) {
          await tester.ensureVisible(find.text(label));
          await _settle(tester);
          expect(find.text(label).hitTestable(), findsOneWidget);
        }
        expect(find.text('Done').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Colour picker opened from the editor.
        await tester.tap(find.text('Card Borders'));
        await _settle(tester);
        expect(find.text('Card Borders Color'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final picker = tester.getRect(
            find.descendant(of: find.byType(AlertDialog).last, matching: find.byType(Material)).first);
        if (fold != null) {
          expect(picker.overlaps(fold.band), isFalse, reason: 'picker $picker');
        }
        expect(find.text('Apply').hitTestable(), findsOneWidget);
        expect(find.text('Cancel').hitTestable(), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await _settle(tester);
        await tester.tap(find.text('Done'));
        await _settle(tester);
        expect(find.byType(AlertDialog), findsNothing);
      });
    }
  });

  group('AppearanceHeroTile', () {
    Widget host(FocusNode node, VoidCallback onSelect) => Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(14),
            children: [AppearanceHeroTile(focusNode: node, onSelect: onSelect)],
          ),
        );

    for (final (size, posture) in [
      (_cover, DuoPosture.closed),
      (_innerPortrait, DuoPosture.fullyOpen),
      (_innerLandscape, DuoPosture.fullyOpen),
      (_innerPortrait, DuoPosture.tabletop),
      (_innerLandscape, DuoPosture.book),
    ]) {
      testWidgets('does not overflow at $size ($posture)', (tester) async {
        final node = FocusNode();
        addTearDown(node.dispose);
        await IPhoneDuoService.setSimulatedPosture(posture);
        await _pump(tester, size, host(node, () {}));
        expect(tester.takeException(), isNull);
        expect(find.text('Edit Appearance & Themes'), findsOneWidget);
      });
    }

    testWidgets('book: a full-width tile moves to the leading half and still works', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      var taps = 0;
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(tester, _innerLandscape, host(node, () => taps++));
      final band = _band(_innerLandscape);

      final tile = tester.getRect(_within(AppearanceHeroTile, InkWell));
      expect(tile.left, 14);
      expect(tile.right, lessThanOrEqualTo(band.left));
      _expectClearOf(band, _visibleGlyphs(tester, AppearanceHeroTile, _innerLandscape), 'text');

      await tester.tap(find.text('Edit Appearance & Themes'));
      await _settle(tester);
      expect(taps, 1);
      node.requestFocus();
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(taps, 2);
    });

    testWidgets('keeps its size when not half folded', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      for (final size in [_innerLandscape, _innerPortrait, _cover]) {
        final rects = <Rect>[];
        for (final posture in [null, DuoPosture.fullyOpen, DuoPosture.closed]) {
          await IPhoneDuoService.setSimulatedPosture(posture);
          await _pump(tester, size, host(node, () {}));
          rects.add(tester.getRect(_within(AppearanceHeroTile, InkWell)));
        }
        expect(rects[0].width, size.width - 28);
        expect(rects[1], rects[0]);
        expect(rects[2], rects[0]);
      }
    });
  });
}
