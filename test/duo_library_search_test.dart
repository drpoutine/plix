import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plix/models/plex_library.dart';
import 'package:plix/models/plex_server.dart';
import 'package:plix/screens/library_screen.dart';
import 'package:plix/screens/search_screen.dart';
import 'package:plix/services/iphone_duo_service.dart';
import 'package:plix/services/plex_media_service.dart';
import 'package:plix/services/plix_device_helper.dart';
import 'package:plix/widgets/duo_fold.dart';
import 'package:plix/widgets/media_card.dart';
import 'package:plix/widgets/plix_back_button.dart';
import 'package:plix/widgets/plix_home_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _cover = Size(466, 678);
const _innerPortrait = Size(669, 951);
const _innerLandscape = Size(951, 669);

const _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// Four titles per letter: "Alpha 1" .. "Zulu 4" style, 104 in total.
List<Map<String, dynamic>> _metadata() {
  final out = <Map<String, dynamic>>[];
  for (var l = 0; l < _letters.length; l++) {
    for (var n = 1; n <= 4; n++) {
      out.add({
        'ratingKey': '${l * 10 + n}',
        'key': '/library/metadata/${l * 10 + n}',
        'type': 'movie',
        'title': '${_letters[l]}film $n',
        'year': 2000 + n,
      });
    }
  }
  return out;
}

final _client = MockClient((request) async {
  final path = request.url.path;
  if (path.contains('/library/sections/')) {
    return http.Response(
        jsonEncode({
          'MediaContainer': {'Metadata': _metadata()}
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
  if (path.contains('/hubs/search')) {
    return http.Response(
        jsonEncode({
          'MediaContainer': {
            'Hub': [
              {'type': 'movie', 'Metadata': _metadata().take(40).toList()}
            ]
          }
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
  return http.Response('{}', 404);
});

PlexServer _server() => PlexServer(
      name: 'Test Server',
      clientIdentifier: 'test_srv',
      accessToken: 'tok',
      owned: true,
      connections: [],
      activeConnectionUri: 'http://plex.test:32400',
    );

Rect _band(WidgetTester tester) {
  final fold = IPhoneDuoService.currentInfo.foldFor(tester.view.physicalSize / tester.view.devicePixelRatio);
  expect(fold, isNotNull, reason: 'the test expects a half folded pose');
  return fold!.band;
}

Future<void> _setUp(WidgetTester tester, Size size, DuoPosture? posture) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await IPhoneDuoService.setSimulatedPosture(posture);
}

Future<void> _settle(WidgetTester tester) async {
  // Fake responses resolve in microtasks; the fold is measured after a frame.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpLibrary(WidgetTester tester, Size size, DuoPosture? posture) async {
  await _setUp(tester, size, posture);
  final server = _server();
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => DuoScope(child: child!),
    home: LibraryScreen(
      library: PlexLibrary(key: '1', title: 'Movies', type: 'movie', serverId: 'test_srv', server: server),
      server: server,
      clientId: 'client',
    ),
  ));
  await _settle(tester);
}

Future<void> _pumpSearch(WidgetTester tester, Size size, DuoPosture? posture, {bool search = true}) async {
  await _setUp(tester, size, posture);
  final server = _server();
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => DuoScope(child: child!),
    home: SearchScreen(server: server, clientId: 'client', isMultiServer: false),
  ));
  await _settle(tester);
  if (search) {
    await tester.enterText(find.byType(EditableText), 'film');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);
  }
}

List<Rect> _cardRects(WidgetTester tester) =>
    find.byType(MediaCard).evaluate().map((e) => tester.getRect(find.byWidget(e.widget))).toList();

int _firstRowCount(List<Rect> rects) => rects.where((r) => (r.top - rects.first.top).abs() < 0.5).length;

/// A hardware-reported spine that is not in the middle, so the two halves
/// hold a different number of columns than the ordinary grid.
void _reportOffCentreSpine() {
  IPhoneDuoService.updateFromNative({
    'isDuo': true,
    'hinge': 'partiallyOpen',
    'angle': 1.6,
    'inner': true,
    'landscape': true,
    'fold': {'x': 380.0, 'y': 0.0, 'width': 60.0, 'height': _innerLandscape.height},
  });
}

Rect _letterCell(WidgetTester tester, String letter) => tester.getRect(
      find.ancestor(of: find.text(letter), matching: find.byType(AnimatedContainer)).first,
    );

void _expectClearOfSpine(Rect rect, Rect band, String what) {
  expect(rect.right <= band.left + 0.01 || rect.left >= band.right - 0.01, isTrue,
      reason: '$what at $rect crosses the spine $band');
}

void _expectClearOfTabletopBand(Rect rect, Rect band, String what) {
  expect(rect.bottom <= band.top + 0.01 || rect.top >= band.bottom - 0.01, isTrue,
      reason: '$what at $rect crosses the fold $band');
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await PlixDeviceHelper.initDeviceName();
    // PlexMediaService creates its shared HTTP client lazily; creating it in
    // this zone makes the screens talk to the fake server above.
    http.runWithClient(() => PlexMediaService(server: _server()), () => _client);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IPhoneDuoService.debugReset();
  });
  tearDown(IPhoneDuoService.debugReset);

  test('the test host is not treated as a TV', () {
    expect(PlixDeviceHelper.isTelevision, isFalse);
  });

  group('LibraryScreen', () {
    testWidgets('book: no poster tile sits on the spine and both halves are used', (tester) async {
      await _pumpLibrary(tester, _innerLandscape, DuoPosture.book);
      expect(tester.takeException(), isNull);
      final band = _band(tester);
      final rects = _cardRects(tester);
      expect(rects.length, greaterThan(6));
      for (final r in rects) {
        _expectClearOfSpine(r, band, 'poster');
      }
      expect(rects.any((r) => r.right <= band.left), isTrue);
      expect(rects.any((r) => r.left >= band.right), isTrue);
      // The alphabet rail keeps its place on the right; tiles stay clear of it.
      final rail = _letterCell(tester, 'A');
      for (final r in rects) {
        expect(r.right, lessThanOrEqualTo(rail.left));
      }
    });

    testWidgets('book: scrolled rows also stay off the spine', (tester) async {
      await _pumpLibrary(tester, _innerLandscape, DuoPosture.book);
      final band = _band(tester);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
      await _settle(tester);
      final rects = _cardRects(tester);
      expect(rects, isNotEmpty);
      for (final r in rects) {
        _expectClearOfSpine(r, band, 'poster');
      }
    });

    testWidgets('flat landscape keeps the ordinary grid (control: a tile does cross the middle)', (tester) async {
      await _pumpLibrary(tester, _innerLandscape, DuoPosture.fullyOpen);
      final flat = _cardRects(tester);
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      final band = _band(tester);
      expect(flat.any((r) => r.left < band.right && r.right > band.left), isTrue,
          reason: 'without the spine layout a tile would sit on the fold');
    });

    testWidgets('closed and flat lay out exactly like a non-Duo device', (tester) async {
      for (final size in [_cover, _innerPortrait, _innerLandscape]) {
        await _pumpLibrary(tester, size, null);
        final plain = _cardRects(tester);
        final plainLetter = _letterCell(tester, 'M');
        expect(plain, isNotEmpty);
        for (final posture in [DuoPosture.closed, DuoPosture.fullyOpen]) {
          await tester.pumpWidget(const SizedBox());
          await _pumpLibrary(tester, size, posture);
          expect(_cardRects(tester), plain, reason: '$posture at $size');
          expect(_letterCell(tester, 'M'), plainLetter, reason: '$posture at $size');
        }
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('book: app bar buttons and alphabet rail are off the spine', (tester) async {
      await _pumpLibrary(tester, _innerLandscape, DuoPosture.book);
      final band = _band(tester);
      final buttons = find.byType(IconButton);
      expect(buttons, findsNWidgets(4));
      for (final e in buttons.evaluate()) {
        _expectClearOfSpine(tester.getRect(find.byWidget(e.widget)), band, 'app bar button');
      }
      _expectClearOfSpine(tester.getRect(find.text('Movies')), band, 'title');
      _expectClearOfSpine(_letterCell(tester, 'A'), band, 'alphabet rail');
    });

    testWidgets('book: jumping to a letter lands on the row that really holds it', (tester) async {
      await _pumpLibrary(tester, _innerLandscape, DuoPosture.book);
      final band = _band(tester);
      // The rail scrolls in landscape; bring the letter into view first.
      await tester.ensureVisible(find.text('T'));
      await _settle(tester);
      await tester.tap(find.text('T'));
      await _settle(tester);
      final target = find.byWidgetPredicate((w) => w is MediaCard && w.item.title == 'Tfilm 1');
      expect(target, findsOneWidget);
      final rect = tester.getRect(target);
      final viewport = tester.getRect(find.byType(CustomScrollView));
      expect(rect.top, greaterThanOrEqualTo(viewport.top - 1));
      expect(rect.top, lessThan(viewport.top + 60), reason: 'the target row should be at the top of the grid');
      _expectClearOfSpine(rect, band, 'target poster');
      // Let the letter badge timer finish.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('book with an off-centre spine: column maths follows the real layout', (tester) async {
      await _pumpLibrary(tester, _innerLandscape, null);
      final flatColumns = _firstRowCount(_cardRects(tester));
      _reportOffCentreSpine();
      await _settle(tester);
      final band = _band(tester);
      expect(band.left, 380);
      final rects = _cardRects(tester);
      final columns = _firstRowCount(rects);
      expect(columns, isNot(flatColumns), reason: 'the case must differ from the ordinary grid to prove anything');
      for (final r in rects) {
        _expectClearOfSpine(r, band, 'poster');
      }
      // Right arrow leaves the grid for the alphabet rail only from the real last column.
      final cards = tester.widgetList<MediaCard>(find.byType(MediaCard)).toList();
      expect(cards[columns - 1].onRight, isNotNull);
      expect(cards[columns - 2].onRight, isNull);
      expect(cards[flatColumns - 1].onRight, isNull);

      await tester.ensureVisible(find.text('T'));
      await _settle(tester);
      await tester.tap(find.text('T'));
      await _settle(tester);
      final target = find.byWidgetPredicate((w) => w is MediaCard && w.item.title == 'Tfilm 1');
      expect(target, findsOneWidget);
      final viewport = tester.getRect(find.byType(CustomScrollView));
      expect(tester.getRect(target).top, greaterThanOrEqualTo(viewport.top - 1));
      expect(tester.getRect(target).top, lessThan(viewport.top + 60));
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('tabletop: no alphabet letter sits in the fold, and all 27 remain', (tester) async {
      await _pumpLibrary(tester, _innerPortrait, DuoPosture.tabletop);
      expect(tester.takeException(), isNull);
      final band = _band(tester);
      var above = 0;
      var below = 0;
      for (final letter in ['#', ..._letters.split('')]) {
        expect(find.text(letter), findsOneWidget, reason: 'letter $letter must stay reachable');
        final cell = _letterCell(tester, letter);
        _expectClearOfTabletopBand(cell, band, 'letter $letter');
        expect(cell.height, greaterThan(12), reason: 'letter $letter must stay tappable');
        if (cell.bottom <= band.top) {
          above++;
        } else {
          below++;
        }
      }
      expect(above, greaterThan(5));
      expect(below, greaterThan(5));
    });

    testWidgets('flat portrait keeps the ordinary rail (control: a letter does cross the middle)', (tester) async {
      await _pumpLibrary(tester, _innerPortrait, DuoPosture.fullyOpen);
      final cells = [for (final l in _letters.split('')) _letterCell(tester, l)];
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      final band = _band(tester);
      expect(cells.any((r) => r.top < band.bottom && r.bottom > band.top), isTrue);
    });

    testWidgets('tabletop: tapping a letter below the fold still jumps', (tester) async {
      await _pumpLibrary(tester, _innerPortrait, DuoPosture.tabletop);
      await tester.tap(find.text('X'));
      await _settle(tester);
      expect(find.byWidgetPredicate((w) => w is MediaCard && w.item.title == 'Xfilm 1'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('tabletop: fixed bars stay clear of the fold', (tester) async {
      await _pumpLibrary(tester, _innerPortrait, DuoPosture.tabletop);
      final band = _band(tester);
      expect(tester.getRect(find.byType(AppBar)).bottom, lessThanOrEqualTo(band.top));
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.bottomNavigationBar, isNotNull);
      expect(tester.getRect(find.byWidget(scaffold.bottomNavigationBar!)).top, greaterThanOrEqualTo(band.bottom));
    });

    testWidgets('no overflow at the three Duo sizes in every pose', (tester) async {
      final cases = <(Size, DuoPosture?)>[
        (_cover, DuoPosture.closed),
        (_innerPortrait, DuoPosture.fullyOpen),
        (_innerPortrait, DuoPosture.tabletop),
        (_innerLandscape, DuoPosture.fullyOpen),
        (_innerLandscape, DuoPosture.book),
      ];
      for (final (size, posture) in cases) {
        await _pumpLibrary(tester, size, posture);
        expect(tester.takeException(), isNull, reason: '$posture at $size');
        expect(find.byType(MediaCard), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('SearchScreen', () {
    testWidgets('book: no result tile sits on the spine and both halves are used', (tester) async {
      await _pumpSearch(tester, _innerLandscape, DuoPosture.book);
      expect(tester.takeException(), isNull);
      final band = _band(tester);
      final rects = _cardRects(tester);
      expect(rects.length, greaterThan(6));
      for (final r in rects) {
        _expectClearOfSpine(r, band, 'result');
      }
      expect(rects.any((r) => r.right <= band.left), isTrue);
      expect(rects.any((r) => r.left >= band.right), isTrue);
    });

    testWidgets('flat landscape keeps the ordinary grid (control: a tile does cross the middle)', (tester) async {
      await _pumpSearch(tester, _innerLandscape, DuoPosture.fullyOpen);
      final flat = _cardRects(tester);
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      final band = _band(tester);
      expect(flat.any((r) => r.left < band.right && r.right > band.left), isTrue);
    });

    testWidgets('closed and flat lay out exactly like a non-Duo device', (tester) async {
      for (final size in [_cover, _innerPortrait, _innerLandscape]) {
        await _pumpSearch(tester, size, null);
        final plain = _cardRects(tester);
        final plainField = tester.getRect(find.byType(EditableText));
        expect(plain, isNotEmpty);
        for (final posture in [DuoPosture.closed, DuoPosture.fullyOpen]) {
          await tester.pumpWidget(const SizedBox());
          await _pumpSearch(tester, size, posture);
          expect(_cardRects(tester), plain, reason: '$posture at $size');
          expect(tester.getRect(find.byType(EditableText)), plainField, reason: '$posture at $size');
        }
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('book: top bar controls are off the spine', (tester) async {
      await _pumpSearch(tester, _innerLandscape, DuoPosture.book, search: false);
      final band = _band(tester);
      _expectClearOfSpine(tester.getRect(find.byType(PlixBackButton)), band, 'back button');
      _expectClearOfSpine(tester.getRect(find.byType(PlixHomeButton)), band, 'home button');
      // The pill around the field is the tap target.
      final pill = tester.getRect(
          find.ancestor(of: find.byType(EditableText), matching: find.byType(AnimatedContainer)).first);
      _expectClearOfSpine(pill, band, 'search field');
      expect(pill.width, greaterThan(200));
      _expectClearOfSpine(tester.getRect(find.text('Search Movies & TV Shows')), band, 'empty state');
    });

    testWidgets('book: the clear button and result count are off the spine', (tester) async {
      await _pumpSearch(tester, _innerLandscape, DuoPosture.book);
      final band = _band(tester);
      _expectClearOfSpine(tester.getRect(find.byIcon(Icons.close_rounded)), band, 'clear button');
      _expectClearOfSpine(tester.getRect(find.text('40 RESULTS')), band, 'result count');
    });

    testWidgets('flat landscape keeps the full-width field (control)', (tester) async {
      await _pumpSearch(tester, _innerLandscape, DuoPosture.fullyOpen, search: false);
      final pill = tester.getRect(
          find.ancestor(of: find.byType(EditableText), matching: find.byType(AnimatedContainer)).first);
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      final band = _band(tester);
      expect(pill.left < band.left && pill.right > band.right, isTrue);
    });

    testWidgets('book: arrow keys follow the spine layout', (tester) async {
      await _pumpSearch(tester, _innerLandscape, DuoPosture.book);
      final cards = tester.widgetList<MediaCard>(find.byType(MediaCard)).toList();
      final rects = _cardRects(tester);
      final columns = rects.where((r) => (r.top - rects.first.top).abs() < 0.5).length;
      FocusNode node(int i) =>
          tester.widget<MediaCard>(find.byWidgetPredicate((w) => w is MediaCard && w.item.title == cards[i].item.title)).focusNode!;
      node(0).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      expect(node(columns).hasFocus, isTrue, reason: 'down moves one real row ($columns columns)');
      // Moving right from the last column of a row must not wrap.
      node(columns - 1).requestFocus();
      await tester.pump();
      expect(cards[columns - 1].onRight, isNull);
      expect(cards[columns - 2].onRight, isNotNull);
    });

    testWidgets('book with an off-centre spine: arrow keys follow the real layout', (tester) async {
      await _pumpSearch(tester, _innerLandscape, null);
      final flatColumns = _firstRowCount(_cardRects(tester));
      _reportOffCentreSpine();
      await _settle(tester);
      final band = _band(tester);
      final rects = _cardRects(tester);
      final columns = _firstRowCount(rects);
      expect(columns, isNot(flatColumns), reason: 'the case must differ from the ordinary grid to prove anything');
      for (final r in rects) {
        _expectClearOfSpine(r, band, 'result');
      }
      final pill = tester.getRect(
          find.ancestor(of: find.byType(EditableText), matching: find.byType(AnimatedContainer)).first);
      _expectClearOfSpine(pill, band, 'search field');

      final cards = tester.widgetList<MediaCard>(find.byType(MediaCard)).toList();
      expect(cards[columns - 1].onRight, isNull);
      expect(cards[columns].onLeft, isNull);
      cards[1].focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      final after = tester.widgetList<MediaCard>(find.byType(MediaCard)).toList();
      expect(after[1 + columns].focusNode!.hasFocus, isTrue);
      expect(tester.getRect(find.byWidget(after[1 + columns])).left, rects[1].left,
          reason: 'down stays in the same visual column');
    });

    testWidgets('tabletop: fixed controls and the empty state are clear of the fold', (tester) async {
      await _pumpSearch(tester, _innerPortrait, DuoPosture.tabletop, search: false);
      expect(tester.takeException(), isNull);
      final band = _band(tester);
      for (final finder in [
        find.byType(PlixBackButton),
        find.byType(PlixHomeButton),
        find.byType(EditableText),
        find.text('Search Movies & TV Shows'),
        find.textContaining('Type in the search box'),
      ]) {
        _expectClearOfTabletopBand(tester.getRect(finder), band, '$finder');
      }
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.bottomNavigationBar, isNotNull);
      expect(tester.getRect(find.byWidget(scaffold.bottomNavigationBar!)).top, greaterThanOrEqualTo(band.bottom));
    });

    testWidgets('no overflow at the three Duo sizes in every pose', (tester) async {
      final cases = <(Size, DuoPosture?)>[
        (_cover, DuoPosture.closed),
        (_innerPortrait, DuoPosture.fullyOpen),
        (_innerPortrait, DuoPosture.tabletop),
        (_innerLandscape, DuoPosture.fullyOpen),
        (_innerLandscape, DuoPosture.book),
      ];
      for (final (size, posture) in cases) {
        await _pumpSearch(tester, size, posture, search: false);
        expect(tester.takeException(), isNull, reason: 'empty state, $posture at $size');
        await tester.pumpWidget(const SizedBox());
        await _pumpSearch(tester, size, posture);
        expect(tester.takeException(), isNull, reason: 'results, $posture at $size');
        expect(find.byType(MediaCard), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });
}
