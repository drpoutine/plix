import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plix/models/plex_media_item.dart';
import 'package:plix/models/plex_server.dart';
import 'package:plix/screens/details_screen.dart';
import 'package:plix/services/iphone_duo_service.dart';
import 'package:plix/services/plex_media_service.dart';
import 'package:plix/services/plix_device_helper.dart';
import 'package:plix/widgets/cast_row.dart';
import 'package:plix/widgets/download_button.dart';
import 'package:plix/widgets/duo_fold.dart';
import 'package:plix/widgets/plix_bottom_nav.dart';
import 'package:plix/widgets/plix_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _cover = Size(466, 678);
const _innerPortrait = Size(669, 951);
const _innerLandscape = Size(951, 669);

const _movieTitle = 'An Extremely Long Feature Film Title That Keeps On Going And Going';
const _summary =
    'A deliberately long synopsis that runs well past the middle of a wide screen when nothing '
    'holds it back, so that the test can tell whether the header block is kept clear of the fold. '
    'It carries on for a few more sentences so that it fills every line the layout allows it. '
    'And then it carries on a little longer still, just to be sure of reaching the last line.';

final _server = PlexServer(
  name: 'Test Server',
  clientIdentifier: 'srv_details',
  accessToken: 'tok',
  owned: true,
  connections: [
    PlexConnection(
      uri: 'http://127.0.0.1:32400',
      protocol: 'http',
      address: '127.0.0.1',
      port: 32400,
      local: true,
      relay: false,
    ),
  ],
);

List<Map<String, dynamic>> _roles() => [
      for (var i = 0; i < 14; i++) {'id': 900 + i, 'tag': 'Actor $i', 'role': 'Character $i'},
    ];

Map<String, dynamic> _media() => {
      'videoResolution': '4k',
      'videoCodec': 'hevc',
      'audioCodec': 'eac3',
      'bitrate': 25000,
      'Part': [
        {'key': '/library/parts/1/file.mkv', 'file': '/media/file.mkv', 'size': 1234567890},
      ],
    };

Map<String, dynamic> _movieJson({int viewOffset = 0}) => {
      'ratingKey': '100',
      'key': '/library/metadata/100',
      'title': _movieTitle,
      'type': 'movie',
      'summary': _summary,
      'year': 2024,
      'originallyAvailableAt': '2024-05-17',
      'duration': 7200000,
      'contentRating': 'PG-13',
      if (viewOffset > 0) 'viewOffset': viewOffset,
      'Media': [_media()],
      'Role': _roles(),
    };

Map<String, dynamic> _showJson() => {
      'ratingKey': '200',
      'key': '/library/metadata/200',
      'title': 'A Television Series With A Remarkably Long Name Indeed',
      'type': 'show',
      'summary': _summary,
      'year': 2021,
      'contentRating': 'TV-MA',
      'librarySectionID': 2,
    };

Map<String, dynamic> _seasonJson(int n) => {
      'ratingKey': '${200 + n}',
      'key': '/library/metadata/${200 + n}/children',
      'title': 'Season $n',
      'type': 'season',
      'index': n,
      'parentRatingKey': '200',
    };

Map<String, dynamic> _episodeJson(int n, {String? title}) => {
      'ratingKey': '${300 + n}',
      'key': '/library/metadata/${300 + n}',
      'title': title ?? 'Episode Number $n With A Long Descriptive Title',
      'type': 'episode',
      'summary': _summary,
      'index': n,
      'parentIndex': 1,
      'parentRatingKey': '201',
      'grandparentRatingKey': '200',
      'grandparentTitle': 'A Television Series With A Remarkably Long Name Indeed',
      'originallyAvailableAt': '2021-03-0$n',
      'duration': 3000000,
      'contentRating': 'TV-MA',
      'Media': [_media()],
    };

http.Response _container(List<Map<String, dynamic>> metadata) => http.Response(
      jsonEncode({
        'MediaContainer': {'size': metadata.length, 'Metadata': metadata},
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// Stands in for the media server. Everything it does not know is a 404,
/// which the screen treats like an unreachable server.
final _client = MockClient((request) async {
  if (request.url.host != '127.0.0.1') return http.Response('', 404);
  final path = request.url.path;
  switch (path) {
    case '/library/metadata/100':
      return _container([_movieJson()]);
    case '/library/metadata/101':
      return _container([
        _movieJson(viewOffset: 600000)..['ratingKey'] = '101',
      ]);
    case '/library/metadata/200':
      return _container([
        _showJson()..['Role'] = _roles(),
      ]);
    case '/library/metadata/200/children':
      return _container([for (var n = 1; n <= 3; n++) _seasonJson(n)]);
    case '/library/metadata/201/children':
    case '/library/metadata/202/children':
    case '/library/metadata/203/children':
      return _container([for (var n = 1; n <= 6; n++) _episodeJson(n)]);
    case '/library/metadata/301':
      return _container([_episodeJson(1)]);
  }
  return http.Response('', 404);
});

PlexMediaItem _movie({String ratingKey = '100'}) => PlexMediaItem.fromJson(_movieJson()..['ratingKey'] = ratingKey);
PlexMediaItem _show() => PlexMediaItem.fromJson(_showJson());
PlexMediaItem _episode() => PlexMediaItem.fromJson(_episodeJson(1));

/// A movie the server does not have, so the screen offers "Not in Library".
PlexMediaItem _missingMovie() => const PlexMediaItem(
      ratingKey: '999',
      key: '/library/metadata/999',
      title: 'Missing',
      type: 'movie',
      librarySectionId: '1',
    );

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
  // Lets the fake server answer, the fold be measured and the layout follow.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(WidgetTester tester, Size size, PlexMediaItem item) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => DuoScope(child: child!),
      home: DetailsScreen(
        key: ValueKey('${item.ratingKey}@$size'),
        initialItem: item,
        server: _server,
        clientId: 'client',
        initialIsOnWatchlist: false,
      ),
    ));
    await _settle(tester);
  }, () => _client);
}

bool _inNestedList(Element element) {
  var nested = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is ListView) {
      nested = true;
      return false;
    }
    return true;
  });
  return nested;
}

/// Text and tap targets of the details page that do not sit in one of its
/// nested lists (cast row, season chips, episode list), with their rects.
Map<String, Rect> _fixedContent(WidgetTester tester) {
  final result = <String, Rect>{};
  void collect(Finder finder, String Function(Widget) describe) {
    var i = 0;
    for (final element in finder.evaluate()) {
      if (_inNestedList(element)) continue;
      final box = element.renderObject;
      if (box is! RenderBox || !box.hasSize || box.size.isEmpty) continue;
      result['${describe(element.widget)} #${i++}'] = box.localToGlobal(Offset.zero) & box.size;
    }
  }

  final page = find.byType(DetailsScreen);
  Finder inPage(Type type) => find.descendant(of: page, matching: find.byType(type)).hitTestable();

  // The bottom navigation bar is another area's widget; only its position is
  // checked here.
  final nav = find.descendant(of: find.byType(PlixBottomNav), matching: find.byType(Text)).evaluate().toSet();
  var i = 0;
  for (final element in inPage(Text).evaluate()) {
    if (nav.contains(element) || _inNestedList(element)) continue;
    final box = element.renderObject as RenderBox;
    if (box.size.isEmpty) continue;
    result['Text "${(element.widget as Text).data}" #${i++}'] = box.localToGlobal(Offset.zero) & box.size;
  }
  collect(inPage(PlixButton), (w) => 'PlixButton "${(w as PlixButton).label}"');
  collect(inPage(DownloadButton), (w) => 'DownloadButton');
  return result;
}

void _expectClearOfBand(Map<String, Rect> content, Rect band) {
  expect(content, isNotEmpty);
  content.forEach((name, rect) {
    expect(rect.overlaps(band), isFalse, reason: '$name at $rect lies in the fold band $band');
  });
}

Rect _rect(WidgetTester tester, Finder finder) => tester.getRect(finder);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The helper assumes a television until the platform has been identified.
  setUpAll(PlixDeviceHelper.initDeviceName);

  // The default test font draws every glyph as a full-width square, which
  // makes labels about twice as wide as on a device and reports overflows
  // that do not exist. Measure with the real Material font instead.
  setUpAll(_loadRoboto);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IPhoneDuoService.debugReset();
  });
  tearDown(IPhoneDuoService.debugReset);

  group('flat and closed', () {
    final sizes = {
      'cover 466x678': (_cover, DuoPosture.closed),
      'inner portrait 669x951': (_innerPortrait, DuoPosture.fullyOpen),
      'inner landscape 951x669': (_innerLandscape, DuoPosture.fullyOpen),
    };
    final items = <String, PlexMediaItem Function()>{
      'movie': _movie,
      'in-progress movie': () => _movie(ratingKey: '101'),
      'show': _show,
      'episode': _episode,
    };

    for (final size in sizes.entries) {
      for (final item in items.entries) {
        testWidgets('${item.key} lays out without overflow on ${size.key}', (tester) async {
          await IPhoneDuoService.setSimulatedPosture(size.value.$2);
          await _pump(tester, size.value.$1, item.value());
          expect(tester.takeException(), isNull);
          expect(IPhoneDuoService.currentInfo.foldFor(size.value.$1), isNull);

          // The whole page still scrolls to its end without trouble.
          await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -600));
          await _settle(tester);
          expect(tester.takeException(), isNull);
        });
      }
    }

    for (final item in items.entries) {
      for (final size in [_innerLandscape, _innerPortrait, _cover]) {
        testWidgets('${item.key} at $size is laid out exactly as on a non-Duo device', (tester) async {
          await _pump(tester, size, item.value());
          final plain = _fixedContent(tester);
          expect(tester.takeException(), isNull);

          await IPhoneDuoService.setSimulatedPosture(size == _cover ? DuoPosture.closed : DuoPosture.fullyOpen);
          await _pump(tester, size, item.value());
          expect(_fixedContent(tester), plain);
        });
      }
    }
  });

  group('book', () {
    setUp(() => IPhoneDuoService.setSimulatedPosture(DuoPosture.book));

    testWidgets('unfolded, the info block does cross the middle (the layout the fold must fix)', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(tester, _innerLandscape, _movie());
      final middle = _innerLandscape.width / 2;
      final summary = _rect(tester, find.text(_summary));
      expect(summary.left, lessThan(middle));
      expect(summary.right, greaterThan(middle));
    });

    for (final entry in <String, PlexMediaItem Function()>{
      'movie': _movie,
      'in-progress movie': () => _movie(ratingKey: '101'),
      'show': _show,
      'episode': _episode,
    }.entries) {
      testWidgets('${entry.key}: header text and buttons stay out of the spine', (tester) async {
        await _pump(tester, _innerLandscape, entry.value());
        expect(tester.takeException(), isNull);
        final band = _band(_innerLandscape);
        _expectClearOfBand(_fixedContent(tester), band);

        // Scrolling down does not bring anything fixed into the spine either.
        await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -300));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        _expectClearOfBand(_fixedContent(tester), band);
      });
    }

    testWidgets('movie: artwork on the left page, title and every action on the right page', (tester) async {
      await _pump(tester, _innerLandscape, _movie());
      final band = _band(_innerLandscape);

      expect(_rect(tester, find.byIcon(Icons.movie)).right, lessThanOrEqualTo(band.left));
      expect(_rect(tester, find.text(_movieTitle)).left, greaterThanOrEqualTo(band.right));
      expect(_rect(tester, find.text(_summary)).left, greaterThanOrEqualTo(band.right));

      for (final label in ['Play', 'Watchlist', 'Mark Watched', 'Get Info', 'Download']) {
        final button = find.widgetWithText(PlixButton, label);
        expect(button, findsOneWidget, reason: '$label must stay available in book');
        final rect = _rect(tester, button);
        expect(rect.left, greaterThanOrEqualTo(band.right), reason: label);
        expect(rect.right, lessThanOrEqualTo(_innerLandscape.width), reason: label);
        // Wrapped onto the page, not shrunk to fit one line.
        expect(rect.height, greaterThanOrEqualTo(30), reason: label);
      }
    });

    testWidgets('episode: still and its buttons fill the left page, info on the right page', (tester) async {
      await _pump(tester, _innerLandscape, _episode());
      final band = _band(_innerLandscape);

      for (final label in ['Play', 'Series', 'Watchlist', 'Watched', 'Get Info']) {
        final button = find.widgetWithText(PlixButton, label);
        expect(button, findsOneWidget, reason: '$label must stay available in book');
        expect(_rect(tester, button).right, lessThanOrEqualTo(band.left), reason: label);
      }
      final download = find.byType(DownloadButton).hitTestable();
      expect(download, findsOneWidget);
      expect(find.descendant(of: download, matching: find.text('Download')), findsOneWidget);
      expect(_rect(tester, download).right, lessThanOrEqualTo(band.left));
      expect(_rect(tester, find.text(_summary)).left, greaterThanOrEqualTo(band.right));
    });

    testWidgets('folding and unfolding moves the block and puts it back', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(tester, _innerLandscape, _movie());
      final flat = _rect(tester, find.text(_summary));

      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _settle(tester);
      expect(_rect(tester, find.text(_summary)).left, greaterThanOrEqualTo(_band(_innerLandscape).right));

      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _settle(tester);
      expect(_rect(tester, find.text(_summary)), flat);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Get Info opens on one page', (tester) async {
      await _pump(tester, _innerLandscape, _movie());
      await tester.tap(find.widgetWithText(PlixButton, 'Get Info'));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final dialog = _rect(tester, find.byType(Dialog));
      expect(dialog.right, lessThanOrEqualTo(_band(_innerLandscape).left));
      expect(_rect(tester, find.text('Media File Information')).right, lessThanOrEqualTo(dialog.right));
      expect(find.widgetWithText(PlixButton, 'Close').hitTestable(), findsOneWidget);
    });

    testWidgets('the "not in library" toast stays on the left page', (tester) async {
      await _pump(tester, _innerLandscape, _missingMovie());
      await tester.tap(find.widgetWithText(PlixButton, 'Not in Library'));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final band = _band(_innerLandscape);
      final toast = find.textContaining('not in this server');
      expect(toast, findsOneWidget);
      expect(_rect(tester, toast).right, lessThanOrEqualTo(band.left));
      final surface = find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first;
      expect(_rect(tester, surface).right, lessThanOrEqualTo(band.left));

      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
    });

    testWidgets('the same toast is centred when flat', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(tester, _innerLandscape, _missingMovie());
      await tester.tap(find.widgetWithText(PlixButton, 'Not in Library'));
      await _settle(tester);

      final toast = _rect(tester, find.textContaining('not in this server'));
      expect(toast.center.dx, closeTo(_innerLandscape.width / 2, 1));

      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
    });
  });

  group('tabletop', () {
    setUp(() => IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop));

    testWidgets('unfolded, the movie title sits across the middle (the layout the fold must fix)', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(tester, _innerPortrait, _movie());
      final title = _rect(tester, find.text(_movieTitle));
      expect(title.top, lessThan(_innerPortrait.height / 2 + 20));
      expect(title.bottom, greaterThan(_innerPortrait.height / 2 - 20));
    });

    testWidgets('movie: title and every control start on the lower half', (tester) async {
      await _pump(tester, _innerPortrait, _movie());
      expect(tester.takeException(), isNull);
      final band = _band(_innerPortrait);

      expect(_rect(tester, find.text(_movieTitle)).top, closeTo(band.bottom, 1));

      final nav = _rect(tester, find.byType(PlixBottomNav));
      expect(nav.top, greaterThan(band.bottom));

      expect(find.widgetWithText(PlixButton, 'Play'), findsOneWidget);
      for (final label in ['Play', 'Watchlist', 'Watched', 'Get Info', 'Download']) {
        final control = find.descendant(of: find.byType(SingleChildScrollView), matching: find.text(label));
        expect(control, findsOneWidget, reason: '$label must stay available in tabletop');
        final rect = _rect(tester, control);
        expect(rect.top, greaterThanOrEqualTo(band.bottom), reason: label);
        expect(rect.bottom, lessThanOrEqualTo(nav.top), reason: '$label must be on screen without scrolling');
      }
    });

    testWidgets('movie: the title position does not drift when the page is scrolled and rebuilt', (tester) async {
      await _pump(tester, _innerPortrait, _movie());
      final before = _rect(tester, find.text(_movieTitle)).top;

      await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -200));
      await _settle(tester);
      // Any rebuild re-measures; the result must not depend on the scroll offset.
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _settle(tester);
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      await _settle(tester);
      await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, 600));
      await _settle(tester);

      expect(_rect(tester, find.text(_movieTitle)).top, closeTo(before, 1));
      expect(tester.takeException(), isNull);
    });

    for (final entry in <String, (PlexMediaItem Function(), String)>{
      'movie': (_movie, _movieTitle),
      'show': (_show, 'A Television Series With A Remarkably Long Name Indeed'),
      'episode': (_episode, 'Episode Number 1 With A Long Descriptive Title'),
    }.entries) {
      testWidgets('${entry.key}: artwork above the fold, title and controls below it', (tester) async {
        await _pump(tester, _innerPortrait, entry.value.$1());
        expect(tester.takeException(), isNull);
        final band = _band(_innerPortrait);

        expect(_rect(tester, find.text(entry.value.$2).first).top, closeTo(band.bottom, 1));
        final content = _fixedContent(tester);
        _expectClearOfBand(content, band);
        expect(content.keys.where((k) => k.startsWith('PlixButton')), isNotEmpty);
        for (final e in content.entries.where((e) => e.key.startsWith('PlixButton'))) {
          expect(e.value.top, greaterThanOrEqualTo(band.bottom), reason: e.key);
        }
        if (entry.key != 'movie') {
          expect(_rect(tester, find.byIcon(Icons.movie)).bottom, lessThanOrEqualTo(band.top));
        }
        expect(_rect(tester, find.byType(PlixBottomNav)).top, greaterThan(band.bottom));

        await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -600));
        await _settle(tester);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Get Info opens on the lower half', (tester) async {
      await _pump(tester, _innerPortrait, _movie());
      await tester.tap(find.text('Get Info'));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final band = _band(_innerPortrait);
      final dialog = _rect(tester, find.byType(Dialog));
      expect(dialog.top, greaterThanOrEqualTo(band.bottom));
      expect(dialog.bottom, lessThanOrEqualTo(_innerPortrait.height));
      final close = find.widgetWithText(PlixButton, 'Close');
      expect(close.hitTestable(), findsOneWidget);
      expect(_rect(tester, close).top, greaterThanOrEqualTo(band.bottom));

      await tester.tap(close);
      await _settle(tester);
      expect(find.byType(Dialog), findsNothing);
    });
  });

  group('cast row', () {
    final people = [
      for (var i = 0; i < 14; i++) MediaPerson(id: '$i', name: 'Actor $i', role: 'Character $i'),
    ];

    for (final entry in {
      'cover': (_cover, DuoPosture.closed),
      'tabletop': (_innerPortrait, DuoPosture.tabletop),
      'book': (_innerLandscape, DuoPosture.book),
    }.entries) {
      testWidgets('scrolls through the fold without overflow (${entry.key})', (tester) async {
        await IPhoneDuoService.setSimulatedPosture(entry.value.$2);
        tester.view.physicalSize = entry.value.$1;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        MediaPerson? tapped;
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => DuoScope(child: child!),
          home: Scaffold(
            body: CastRow(
              people: people,
              mediaService: PlexMediaService(server: _server, client: _client),
              onPersonTap: (p) => tapped = p,
            ),
          ),
        ));
        await _settle(tester);
        expect(tester.takeException(), isNull);

        await tester.drag(find.byType(ListView), const Offset(-2000, 0));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        // The last card can always be brought clear of the fold and tapped.
        await tester.tap(find.text('Actor 13'));
        expect(tapped?.name, 'Actor 13');
      });
    }
  });
}
