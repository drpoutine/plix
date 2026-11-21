import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plix/models/plex_library.dart';
import 'package:plix/models/plex_media_item.dart';
import 'package:plix/models/plex_server.dart';
import 'package:plix/screens/downloads_screen.dart';
import 'package:plix/screens/favorite_libraries_screen.dart';
import 'package:plix/screens/person_screen.dart';
import 'package:plix/screens/recently_added_screen.dart';
import 'package:plix/screens/watchlist_screen.dart';
import 'package:plix/services/download_service.dart';
import 'package:plix/services/iphone_duo_service.dart';
import 'package:plix/services/plex_auth_service.dart';
import 'package:plix/services/plex_media_service.dart';
import 'package:plix/services/plex_server_service.dart';
import 'package:plix/services/plix_device_helper.dart';
import 'package:plix/widgets/duo_fold.dart';
import 'package:plix/widgets/media_card.dart';
import 'package:plix/widgets/plix_back_button.dart';
import 'package:plix/widgets/plix_button.dart';
import 'package:plix/widgets/plix_home_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _cover = Size(466, 678);
const _innerPortrait = Size(669, 951);
const _innerLandscape = Size(951, 669);

const _libraryTitles = ['Movies', 'TV Shows', 'Anime', 'Documentaries', 'Concerts', 'Kids', 'Home Videos'];

List<Map<String, dynamic>> _metadata(int count) => [
      for (var i = 1; i <= count; i++)
        {
          'ratingKey': '$i',
          'key': '/library/metadata/$i',
          'type': 'movie',
          'title': 'Film $i',
          'year': 2000 + (i % 20),
          'librarySectionID': 1,
        },
    ];

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

final _client = MockClient((request) async {
  final path = request.url.path;
  if (path.contains('/library/sections/boom/')) {
    throw const SocketException('server is down');
  }
  if (path.contains('/library/sections/none/')) {
    return _json({
      'MediaContainer': {'Metadata': <dynamic>[]}
    });
  }
  if (path.endsWith('/recentlyAdded')) {
    return _json({
      'MediaContainer': {'totalSize': 60, 'Metadata': _metadata(60)}
    });
  }
  if (path.endsWith('/library/sections/watchlist/all')) {
    return _json({
      'MediaContainer': {'totalSize': 40, 'Metadata': _metadata(40)}
    });
  }
  if (path == '/library/sections') {
    return _json({
      'MediaContainer': {
        'Directory': [
          for (var i = 0; i < _libraryTitles.length; i++)
            {'key': '${i + 1}', 'title': _libraryTitles[i], 'type': i.isEven ? 'movie' : 'show'},
        ]
      }
    });
  }
  if (path.endsWith('/library/people/77')) {
    return _json({
      'MediaContainer': {
        'Metadata': [
          {
            'title': 'Ada Example',
            'summary': List.filled(30, 'A long biography sentence that would run across the whole header.').join(' '),
          }
        ]
      }
    });
  }
  if (path.endsWith('/library/people/77/media')) {
    return _json({
      'MediaContainer': {'Metadata': _metadata(30)}
    });
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

/// The band the fold would reserve at this size if it were half folded.
Rect _bandIfFolded(WidgetTester tester) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  return const IPhoneDuoInfo(isDuo: true, hinge: DuoHingeStatus.partiallyOpen, isInnerDisplay: true)
      .foldFor(size)!
      .band;
}

Future<void> _setUp(WidgetTester tester, Size size, DuoPosture? posture) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await IPhoneDuoService.setSimulatedPosture(posture);
}

Future<void> _settle(WidgetTester tester) async {
  // Fake responses resolve in microtasks; the fold is measured after a frame.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester tester, Size size, DuoPosture? posture, Widget home) async {
  await _setUp(tester, size, posture);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => DuoScope(child: child!),
    home: home,
  ));
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

Widget _recentlyAdded({String key = '1', String title = 'Movies'}) {
  final server = _server();
  return RecentlyAddedScreen(
    library: PlexLibrary(key: key, title: title, type: 'movie', serverId: 'test_srv', server: server),
    server: server,
    clientId: 'client',
  );
}

Widget _watchlist() => WatchlistScreen(server: _server(), authService: PlexAuthService(), clientId: 'client');

Widget _person() => PersonScreen(
      person: const MediaPerson(id: '77', name: 'Ada Example', role: 'Lead'),
      server: _server(),
      clientId: 'client',
    );

Widget _downloads() {
  final auth = PlexAuthService();
  return DownloadsScreen(
    server: _server(),
    authService: auth,
    serverService: PlexServerService(authService: auth),
    clientId: 'client',
  );
}

Future<Widget> _favorites() async {
  final auth = PlexAuthService();
  final service = PlexServerService(authService: auth);
  final server = _server();
  await service.cacheServerLibraries('test_srv', [
    for (var i = 0; i < _libraryTitles.length; i++)
      PlexLibrary(key: '${i + 1}', title: _libraryTitles[i], type: i.isEven ? 'movie' : 'show', serverId: 'test_srv'),
  ]);
  return FavoriteLibrariesScreen(authService: auth, serverService: service, servers: [server]);
}

List<Rect> _rects(WidgetTester tester, Finder finder) => finder.evaluate().map((e) {
      final box = e.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    }).toList();

List<Rect> _cardRects(WidgetTester tester) => _rects(tester, find.byType(MediaCard));

int _firstRowCount(List<Rect> rects) => rects.where((r) => (r.top - rects.first.top).abs() < 0.5).length;

bool _onSpine(Rect rect, Rect band) => rect.left < band.right - 0.01 && rect.right > band.left + 0.01;

void _expectClearOfSpine(Rect rect, Rect band, String what) {
  expect(_onSpine(rect, band), isFalse, reason: '$what at $rect crosses the spine $band');
}

void _expectClearOfTabletopBand(Rect rect, Rect band, String what) {
  expect(rect.bottom <= band.top + 0.01 || rect.top >= band.bottom - 0.01, isTrue,
      reason: '$what at $rect crosses the fold $band');
}

void _expectPostersSplitAroundSpine(WidgetTester tester) {
  final band = _band(tester);
  final rects = _cardRects(tester);
  expect(rects.length, greaterThan(3));
  for (final r in rects) {
    _expectClearOfSpine(r, band, 'poster');
  }
  expect(rects.any((r) => r.right <= band.left), isTrue, reason: 'left half unused');
  expect(rects.any((r) => r.left >= band.right), isTrue, reason: 'right half unused');
}

double _scrollOffset(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

Finder _libraryCard(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(AnimatedContainer)).first;

/// Every size and pose the hardware can present.
const _poses = <(Size, DuoPosture?)>[
  (_cover, null),
  (_cover, DuoPosture.closed),
  (_innerPortrait, null),
  (_innerPortrait, DuoPosture.fullyOpen),
  (_innerPortrait, DuoPosture.tabletop),
  (_innerLandscape, null),
  (_innerLandscape, DuoPosture.fullyOpen),
  (_innerLandscape, DuoPosture.book),
];

Directory? _downloadDir;

DownloadTask _task(String key, String type, DownloadStatus status, String dir, {String? series}) {
  final file = File('$dir/$key.mp4')..writeAsStringSync('x');
  return DownloadTask(
    ratingKey: key,
    title: 'Download $key',
    type: type,
    seriesTitle: series,
    seriesRatingKey: series == null ? null : 'show_$series',
    seasonIndex: series == null ? null : 1,
    episodeIndex: series == null ? null : 1,
    downloadUrl: 'http://plex.test:32400/$key.mp4',
    localFilePath: file.path,
    serverId: 'test_srv',
    serverName: 'Test Server',
    serverType: 'plex',
    totalBytes: 1000,
    receivedBytes: status == DownloadStatus.completed ? 1000 : 400,
    status: status,
  );
}

/// Loads a real index from disk: 14 finished movies, 6 finished shows and 8
/// interrupted downloads that tests can flip back to "downloading".
Future<void> _seedDownloads() async {
  final dir = Directory.systemTemp.createTempSync('plix_duo_downloads');
  _downloadDir = dir;
  final tasks = [
    for (var i = 0; i < 14; i++) _task('m$i', 'movie', DownloadStatus.completed, dir.path),
    for (var i = 0; i < 6; i++) _task('e$i', 'episode', DownloadStatus.completed, dir.path, series: 'Show $i'),
    for (var i = 0; i < 8; i++) _task('a$i', 'movie', DownloadStatus.cancelled, dir.path),
  ];
  File('${dir.path}/downloads_index.json').writeAsStringSync(jsonEncode([for (final t in tasks) t.toJson()]));
  SharedPreferences.setMockInitialValues({'custom_download_path': dir.path});
  await DownloadService.instance.init();
}

void _setActiveDownloads(int count) {
  for (final task in DownloadService.instance.tasks) {
    if (!task.ratingKey.startsWith('a')) continue;
    final index = int.parse(task.ratingKey.substring(1));
    task.status = index < count ? DownloadStatus.downloading : DownloadStatus.cancelled;
  }
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

  group('RecentlyAddedScreen', () {
    testWidgets('book: no poster tile sits on the spine and both halves are used', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book, _recentlyAdded());
      expect(tester.takeException(), isNull);
      _expectPostersSplitAroundSpine(tester);
      await tester.drag(find.byType(GridView), const Offset(0, -600));
      await _settle(tester);
      _expectPostersSplitAroundSpine(tester);
      await _unmount(tester);
    });

    testWidgets('flat landscape keeps the ordinary grid (control: a tile does cross the middle)', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _recentlyAdded());
      final band = _bandIfFolded(tester);
      expect(_cardRects(tester).any((r) => _onSpine(r, band)), isTrue);
      await _unmount(tester);
    });

    testWidgets('book: top bar buttons and the title stay left of the spine', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book,
          _recentlyAdded(title: 'A Library With A Really Rather Long Name That Keeps Going'));
      final band = _band(tester);
      _expectClearOfSpine(tester.getRect(find.byType(PlixBackButton)), band, 'back button');
      _expectClearOfSpine(tester.getRect(find.byType(PlixHomeButton)), band, 'home button');
      final title = tester.getRect(find.textContaining('Recently Added in'));
      _expectClearOfSpine(title, band, 'title');
      expect(title.right, lessThanOrEqualTo(band.left));
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });

    testWidgets('flat landscape: the long title does run across the middle (control)', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen,
          _recentlyAdded(title: 'A Library With A Really Rather Long Name That Keeps Going'));
      expect(_onSpine(tester.getRect(find.textContaining('Recently Added in')), _bandIfFolded(tester)), isTrue);
      await _unmount(tester);
    });

    testWidgets('the Retry button is kept out of the fold in book and tabletop', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _recentlyAdded(key: 'boom'));
      expect(_onSpine(tester.getRect(find.byType(ElevatedButton)), _bandIfFolded(tester)), isTrue,
          reason: 'control: centred, the button is on the spine');
      await _unmount(tester);

      await _pump(tester, _innerLandscape, DuoPosture.book, _recentlyAdded(key: 'boom'));
      _expectClearOfSpine(tester.getRect(find.byType(ElevatedButton)), _band(tester), 'Retry');
      _expectClearOfSpine(tester.getRect(find.textContaining('Failed to load')), _band(tester), 'error text');
      await _unmount(tester);

      await _pump(tester, _innerPortrait, DuoPosture.tabletop, _recentlyAdded(key: 'boom'));
      final retry = tester.getRect(find.byType(ElevatedButton));
      _expectClearOfTabletopBand(retry, _band(tester), 'Retry');
      expect(retry.top, greaterThanOrEqualTo(_band(tester).bottom), reason: 'controls belong on the lower half');
      _expectClearOfTabletopBand(tester.getRect(find.textContaining('Failed to load')), _band(tester), 'error text');
      await _unmount(tester);
    });

    testWidgets('the empty message is kept out of the fold', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book, _recentlyAdded(key: 'none'));
      _expectClearOfSpine(tester.getRect(find.text('No recently added items found.')), _band(tester), 'empty text');
      await _unmount(tester);
      await _pump(tester, _innerPortrait, DuoPosture.tabletop, _recentlyAdded(key: 'none'));
      _expectClearOfTabletopBand(
          tester.getRect(find.text('No recently added items found.')), _band(tester), 'empty text');
      await _unmount(tester);
    });

    testWidgets('book: keyboard focus uses the real first row, not the unfolded column count', (tester) async {
      // Flat: five columns, so the fifth poster is in the first row and
      // focusing it scrolls back to the top.
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _recentlyAdded());
      expect(_firstRowCount(_cardRects(tester)), 5);
      await tester.drag(find.byType(GridView), const Offset(0, -150));
      await _settle(tester);
      expect(_scrollOffset(tester), greaterThan(100));
      tester.widget<MediaCard>(find.byType(MediaCard).at(4)).focusNode!.requestFocus();
      await _settle(tester);
      expect(_scrollOffset(tester), 0);
      await _unmount(tester);

      // Book: four columns, so the same poster starts the second row and
      // must not throw the list back to the top.
      await _pump(tester, _innerLandscape, DuoPosture.book, _recentlyAdded());
      expect(_firstRowCount(_cardRects(tester)), 4);
      await tester.drag(find.byType(GridView), const Offset(0, -150));
      await _settle(tester);
      final before = _scrollOffset(tester);
      expect(before, greaterThan(100));
      tester.widget<MediaCard>(find.byType(MediaCard).at(4)).focusNode!.requestFocus();
      await _settle(tester);
      expect(_scrollOffset(tester), greaterThan(100));
      // A poster that really is in the first row still does.
      tester.widget<MediaCard>(find.byType(MediaCard).at(3)).focusNode!.requestFocus();
      await _settle(tester);
      expect(_scrollOffset(tester), 0);
      await _unmount(tester);
    });

    testWidgets('closed and flat lay out exactly like a non-Duo device', (tester) async {
      for (final size in [_cover, _innerPortrait, _innerLandscape]) {
        await _pump(tester, size, null, _recentlyAdded());
        final plain = _cardRects(tester);
        final plainTitle = tester.getRect(find.textContaining('Recently Added in'));
        expect(plain, isNotEmpty);
        for (final posture in [DuoPosture.closed, DuoPosture.fullyOpen]) {
          await _unmount(tester);
          await _pump(tester, size, posture, _recentlyAdded());
          expect(_cardRects(tester), plain, reason: '$posture at $size');
          expect(tester.getRect(find.textContaining('Recently Added in')), plainTitle, reason: '$posture at $size');
        }
        await _unmount(tester);
      }
    });

    testWidgets('tabletop keeps the portrait grid and its fixed controls clear of the fold', (tester) async {
      await _pump(tester, _innerPortrait, null, _recentlyAdded());
      final plain = _cardRects(tester);
      await _unmount(tester);
      await _pump(tester, _innerPortrait, DuoPosture.tabletop, _recentlyAdded());
      expect(_cardRects(tester), plain);
      final band = _band(tester);
      _expectClearOfTabletopBand(tester.getRect(find.byType(PlixBackButton)), band, 'back button');
      _expectClearOfTabletopBand(tester.getRect(find.byType(PlixHomeButton)), band, 'home button');
      await _unmount(tester);
    });

    testWidgets('no overflow or layout error in any pose', (tester) async {
      for (final (size, posture) in _poses) {
        for (final key in ['1', 'boom', 'none']) {
          await _pump(tester, size, posture, _recentlyAdded(key: key));
          expect(tester.takeException(), isNull, reason: '$posture at $size (library $key)');
          await _unmount(tester);
        }
      }
    });
  });

  group('WatchlistScreen', () {
    testWidgets('book: no poster tile sits on the spine and both halves are used', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book, _watchlist());
      expect(tester.takeException(), isNull);
      _expectPostersSplitAroundSpine(tester);
      await tester.drag(find.byType(GridView), const Offset(0, -600));
      await _settle(tester);
      _expectPostersSplitAroundSpine(tester);
      await _unmount(tester);
    });

    testWidgets('flat landscape keeps the ordinary grid (control: a tile does cross the middle)', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _watchlist());
      expect(_cardRects(tester).any((r) => _onSpine(r, _bandIfFolded(tester))), isTrue);
      await _unmount(tester);
    });

    // A no-regression check, not proof of fold handling: the bar's content is
    // fixed and short, so it ends well left of the middle when flat as well.
    testWidgets('book: the short fixed top bar ends left of the spine, exactly as when flat', (tester) async {
      Map<String, Rect> bar() => {
            'back button': tester.getRect(find.byType(PlixBackButton)),
            'home button': tester.getRect(find.byType(PlixHomeButton)),
            'title': tester.getRect(find.text('Watchlist').first),
            'count': tester.getRect(find.text('40')),
          };
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _watchlist());
      final flat = bar();
      await _unmount(tester);

      await _pump(tester, _innerLandscape, DuoPosture.book, _watchlist());
      final band = _band(tester);
      final book = bar();
      book.forEach((what, rect) {
        expect(rect.right, lessThanOrEqualTo(band.left + 0.01), reason: '$what at $rect is not left of the spine $band');
      });
      expect(book, flat);
      await _unmount(tester);
    });

    testWidgets('book: keyboard focus uses the real first row', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book, _watchlist());
      expect(_firstRowCount(_cardRects(tester)), 4);
      await tester.drag(find.byType(GridView), const Offset(0, -150));
      await _settle(tester);
      expect(_scrollOffset(tester), greaterThan(100));
      tester.widget<MediaCard>(find.byType(MediaCard).at(4)).focusNode!.requestFocus();
      await _settle(tester);
      expect(_scrollOffset(tester), greaterThan(100));
      tester.widget<MediaCard>(find.byType(MediaCard).at(3)).focusNode!.requestFocus();
      await _settle(tester);
      expect(_scrollOffset(tester), 0);
      await _unmount(tester);
    });

    testWidgets('closed and flat lay out exactly like a non-Duo device', (tester) async {
      for (final size in [_cover, _innerPortrait, _innerLandscape]) {
        await _pump(tester, size, null, _watchlist());
        final plain = _cardRects(tester);
        expect(plain, isNotEmpty);
        for (final posture in [DuoPosture.closed, DuoPosture.fullyOpen]) {
          await _unmount(tester);
          await _pump(tester, size, posture, _watchlist());
          expect(_cardRects(tester), plain, reason: '$posture at $size');
        }
        await _unmount(tester);
      }
    });

    testWidgets('tabletop keeps the portrait grid and its fixed controls clear of the fold', (tester) async {
      await _pump(tester, _innerPortrait, null, _watchlist());
      final plain = _cardRects(tester);
      await _unmount(tester);
      await _pump(tester, _innerPortrait, DuoPosture.tabletop, _watchlist());
      expect(_cardRects(tester), plain);
      final band = _band(tester);
      _expectClearOfTabletopBand(tester.getRect(find.byType(PlixBackButton)), band, 'back button');
      _expectClearOfTabletopBand(tester.getRect(find.text('Watchlist').first), band, 'title');
      await _unmount(tester);
    });

    testWidgets('no overflow or layout error in any pose', (tester) async {
      for (final (size, posture) in _poses) {
        await _pump(tester, size, posture, _watchlist());
        expect(tester.takeException(), isNull, reason: '$posture at $size');
        await _unmount(tester);
      }
    });
  });

  group('PersonScreen', () {
    testWidgets('book: no poster tile sits on the spine and both halves are used', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book, _person());
      expect(tester.takeException(), isNull);
      _expectPostersSplitAroundSpine(tester);
      await _unmount(tester);
    });

    testWidgets('flat landscape keeps the ordinary grid (control: a tile does cross the middle)', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _person());
      expect(_cardRects(tester).any((r) => _onSpine(r, _bandIfFolded(tester))), isTrue);
      await _unmount(tester);
    });

    testWidgets('book: each card is exactly as wide and tall as its tile', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book, _person());
      final cards = find.byType(MediaCard);
      final grid = tester.renderObject<RenderSliverGrid>(find.byType(SliverGrid));
      final layout = grid.gridDelegate.getLayout(grid.constraints);
      final tile = layout.getGeometryForChildIndex(0);
      for (final element in cards.evaluate()) {
        final card = element.widget as MediaCard;
        expect(card.width, moreOrLessEquals(tile.crossAxisExtent, epsilon: 0.01));
        expect(tester.getSize(find.byWidget(card)).width, moreOrLessEquals(card.width, epsilon: 0.01));
      }
      // The tile keeps the poster-plus-caption shape the screen sizes for.
      expect(tile.mainAxisExtent, moreOrLessEquals(tile.crossAxisExtent * 1.5 + 58, epsilon: 0.01));
      await _unmount(tester);
    });

    testWidgets('book: arrow keys move by the columns that are actually drawn', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book, _person());
      final rects = _cardRects(tester);
      final columns = _firstRowCount(rects);
      // Rows below the fold of the viewport are built but not on stage.
      final all = find.byType(MediaCard, skipOffstage: false);
      MediaCard card(int i) => tester.widget<MediaCard>(all.at(i));

      card(0).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      expect(card(columns).focusNode!.hasFocus, isTrue, reason: 'down goes to the tile directly below');
      expect(_rects(tester, all)[columns].left, moreOrLessEquals(rects[0].left));

      // The last tile of a row does not wrap on to the next row.
      card(columns - 1).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settle(tester);
      expect(card(columns).focusNode!.hasFocus, isFalse);

      // Right crosses the spine from the left half to the right half.
      card(columns ~/ 2 - 1).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settle(tester);
      expect(card(columns ~/ 2).focusNode!.hasFocus, isTrue);
      await _unmount(tester);
    });

    testWidgets('book: the fixed header stays left of the spine', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book, _person());
      final band = _band(tester);
      final bio = tester.getRect(find.textContaining('A long biography sentence'));
      _expectClearOfSpine(bio, band, 'biography');
      _expectClearOfSpine(tester.getRect(find.text('Ada Example')), band, 'name');
      _expectClearOfSpine(tester.getRect(find.text('Appears in')), band, 'section title');
      _expectClearOfSpine(tester.getRect(find.byType(PlixBackButton)), band, 'back button');
      _expectClearOfSpine(tester.getRect(find.byType(PlixHomeButton)), band, 'home button');
      await _unmount(tester);
    });

    testWidgets('flat landscape: the biography does run across the middle (control)', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _person());
      expect(_onSpine(tester.getRect(find.textContaining('A long biography sentence')), _bandIfFolded(tester)), isTrue);
      await _unmount(tester);
    });

    testWidgets('closed and flat lay out exactly like a non-Duo device', (tester) async {
      for (final size in [_cover, _innerPortrait, _innerLandscape]) {
        await _pump(tester, size, null, _person());
        final plain = _cardRects(tester);
        final plainBio = tester.getRect(find.textContaining('A long biography sentence'));
        expect(plain, isNotEmpty);
        for (final posture in [DuoPosture.closed, DuoPosture.fullyOpen]) {
          await _unmount(tester);
          await _pump(tester, size, posture, _person());
          expect(_cardRects(tester), plain, reason: '$posture at $size');
          expect(tester.getRect(find.textContaining('A long biography sentence')), plainBio,
              reason: '$posture at $size');
        }
        await _unmount(tester);
      }
    });

    testWidgets('tabletop keeps the portrait layout', (tester) async {
      await _pump(tester, _innerPortrait, null, _person());
      final plain = _cardRects(tester);
      final plainBio = tester.getRect(find.textContaining('A long biography sentence'));
      await _unmount(tester);
      await _pump(tester, _innerPortrait, DuoPosture.tabletop, _person());
      expect(_cardRects(tester), plain);
      expect(tester.getRect(find.textContaining('A long biography sentence')), plainBio);
      _expectClearOfTabletopBand(tester.getRect(find.byType(PlixBackButton)), _band(tester), 'back button');
      await _unmount(tester);
    });

    testWidgets('no overflow or layout error in any pose', (tester) async {
      for (final (size, posture) in _poses) {
        await _pump(tester, size, posture, _person());
        expect(tester.takeException(), isNull, reason: '$posture at $size');
        await _unmount(tester);
      }
    });
  });

  group('DownloadsScreen with nothing downloaded', () {
    testWidgets('the empty message is kept out of the fold', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _downloads());
      expect(_onSpine(tester.getRect(find.text('No Downloads Yet')), _bandIfFolded(tester)), isTrue,
          reason: 'control: centred, the message is on the spine');
      await _unmount(tester);

      await _pump(tester, _innerLandscape, DuoPosture.book, _downloads());
      _expectClearOfSpine(tester.getRect(find.text('No Downloads Yet')), _band(tester), 'title');
      _expectClearOfSpine(tester.getRect(find.textContaining('Downloaded movies and episodes')), _band(tester), 'text');
      expect(tester.takeException(), isNull);
      await _unmount(tester);

      await _pump(tester, _innerPortrait, DuoPosture.tabletop, _downloads());
      _expectClearOfTabletopBand(tester.getRect(find.text('No Downloads Yet')), _band(tester), 'title');
      _expectClearOfTabletopBand(
          tester.getRect(find.textContaining('Downloaded movies and episodes')), _band(tester), 'text');
      _expectClearOfTabletopBand(tester.getRect(find.byIcon(Icons.download_done_rounded)), _band(tester), 'icon');
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });

    testWidgets('no overflow in any pose', (tester) async {
      for (final (size, posture) in _poses) {
        await _pump(tester, size, posture, _downloads());
        expect(tester.takeException(), isNull, reason: '$posture at $size');
        await _unmount(tester);
      }
    });
  });

  group('DownloadsScreen', () {
    setUpAll(_seedDownloads);
    tearDownAll(() async {
      // The service is a singleton: empty it again, or groups that expect
      // nothing downloaded fail whenever they run after this one.
      for (final task in DownloadService.instance.tasks) {
        task.status = DownloadStatus.cancelled; // not running, so it is removed directly
        await DownloadService.instance.deleteDownload(task.ratingKey);
      }
      expect(DownloadService.instance.tasks, isEmpty);
      try {
        _downloadDir?.deleteSync(recursive: true);
      } catch (_) {}
    });
    setUp(() => _setActiveDownloads(0));

    Finder chip(String label) => find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;

    testWidgets('book: no poster tile sits on the spine and both halves are used', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.book, _downloads());
      expect(tester.takeException(), isNull);
      _expectPostersSplitAroundSpine(tester);
      await _unmount(tester);
    });

    testWidgets('flat landscape keeps the ordinary grid (control: a tile does cross the middle)', (tester) async {
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _downloads());
      expect(_cardRects(tester).any((r) => _onSpine(r, _bandIfFolded(tester))), isTrue);
      await _unmount(tester);
    });

    testWidgets('book: top bar, filter chips and the active list stay off the spine', (tester) async {
      _setActiveDownloads(2);
      await _pump(tester, _innerLandscape, DuoPosture.book, _downloads());
      final band = _band(tester);
      _expectClearOfSpine(tester.getRect(find.byType(PlixBackButton)), band, 'back button');
      _expectClearOfSpine(tester.getRect(find.byType(PlixHomeButton)), band, 'home button');
      _expectClearOfSpine(tester.getRect(find.text('Downloads')), band, 'title');
      _expectClearOfSpine(tester.getRect(find.text('2 downloading')), band, 'badge');
      for (final label in ['All', 'TV Shows', 'Movies']) {
        _expectClearOfSpine(tester.getRect(chip(label)), band, '$label chip');
      }
      final cancels = _rects(tester, find.byIcon(Icons.close_rounded));
      expect(cancels, hasLength(2));
      for (final r in cancels) {
        _expectClearOfSpine(r, band, 'cancel button');
      }
      for (final r in _rects(tester, find.byType(LinearProgressIndicator))) {
        _expectClearOfSpine(r, band, 'progress bar');
      }
      _expectClearOfSpine(tester.getRect(find.textContaining('Download a0')), band, 'download title');
      _expectPostersSplitAroundSpine(tester);
      expect(tester.takeException(), isNull);

      // The chips still work there.
      await tester.tap(chip('Movies'));
      await _settle(tester);
      expect(find.text('Show 0'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('flat landscape: the active list does run across the middle (control)', (tester) async {
      _setActiveDownloads(2);
      await _pump(tester, _innerLandscape, DuoPosture.fullyOpen, _downloads());
      expect(
          _rects(tester, find.byType(LinearProgressIndicator)).every((r) => _onSpine(r, _bandIfFolded(tester))), isTrue);
      await _unmount(tester);
    });

    testWidgets('tabletop: a long active list scrolls in the upper half instead of pushing controls into the fold',
        (tester) async {
      _setActiveDownloads(8);
      await _pump(tester, _innerPortrait, DuoPosture.fullyOpen, _downloads());
      final flatBand = _bandIfFolded(tester);
      expect(tester.getRect(chip('All')).bottom, greaterThan(flatBand.top),
          reason: 'control: flat, the list pushes the chips down to the fold or past it');
      expect(
          _rects(tester, find.byIcon(Icons.close_rounded))
              .any((r) => r.top < flatBand.bottom && r.bottom > flatBand.top),
          isTrue,
          reason: 'control: flat, a cancel button lands in the band');
      await _unmount(tester);

      await _pump(tester, _innerPortrait, DuoPosture.tabletop, _downloads());
      expect(tester.takeException(), isNull);
      final band = _band(tester);
      for (final label in ['All', 'TV Shows', 'Movies']) {
        final r = tester.getRect(chip(label));
        expect(r.bottom, lessThanOrEqualTo(band.top), reason: '$label chip');
      }
      _expectClearOfTabletopBand(tester.getRect(find.byType(PlixBackButton)), band, 'back button');

      // Every download can still be cancelled: the list scrolls.
      final lastCancel = find.byIcon(Icons.close_rounded).last;
      await tester.scrollUntilVisible(lastCancel, 80, scrollable: find.byType(Scrollable).first);
      await _settle(tester);
      final r = tester.getRect(lastCancel);
      expect(r.bottom, lessThanOrEqualTo(band.top));
      expect(find.textContaining('Download a7'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('tabletop: a short active list is laid out exactly as when flat', (tester) async {
      _setActiveDownloads(2);
      await _pump(tester, _innerPortrait, null, _downloads());
      final plainCards = _cardRects(tester);
      final plainChip = tester.getRect(chip('All'));
      final plainCancels = _rects(tester, find.byIcon(Icons.close_rounded));
      await _unmount(tester);
      await _pump(tester, _innerPortrait, DuoPosture.tabletop, _downloads());
      expect(_cardRects(tester), plainCards);
      expect(tester.getRect(chip('All')), plainChip);
      expect(_rects(tester, find.byIcon(Icons.close_rounded)), plainCancels);
      await _unmount(tester);
    });

    testWidgets('closed and flat lay out exactly like a non-Duo device', (tester) async {
      for (final active in [0, 2]) {
        _setActiveDownloads(active);
        for (final size in [_cover, _innerPortrait, _innerLandscape]) {
          await _pump(tester, size, null, _downloads());
          final plain = _cardRects(tester);
          final plainChip = tester.getRect(chip('All'));
          final plainBars = _rects(tester, find.byType(LinearProgressIndicator));
          expect(plain, isNotEmpty);
          for (final posture in [DuoPosture.closed, DuoPosture.fullyOpen]) {
            await _unmount(tester);
            await _pump(tester, size, posture, _downloads());
            expect(_cardRects(tester), plain, reason: '$posture at $size');
            expect(tester.getRect(chip('All')), plainChip, reason: '$posture at $size');
            expect(_rects(tester, find.byType(LinearProgressIndicator)), plainBars, reason: '$posture at $size');
          }
          await _unmount(tester);
        }
      }
    });

    testWidgets('no overflow or layout error in any pose', (tester) async {
      for (final active in [0, 2]) {
        _setActiveDownloads(active);
        for (final (size, posture) in _poses) {
          await _pump(tester, size, posture, _downloads());
          expect(tester.takeException(), isNull, reason: '$posture at $size with $active active');
          await _unmount(tester);
        }
      }
    });
  });

  group('FavoriteLibrariesScreen', () {
    Future<void> pumpFavorites(WidgetTester tester, Size size, DuoPosture? posture) async {
      await _pump(tester, size, posture, await _favorites());
      await _settle(tester);
    }

    List<Rect> cardRects(WidgetTester tester) =>
        [for (final title in _libraryTitles) tester.getRect(_libraryCard(title))];

    testWidgets('book: no library card sits on the spine and both halves are used', (tester) async {
      await pumpFavorites(tester, _innerLandscape, DuoPosture.book);
      expect(tester.takeException(), isNull);
      final band = _band(tester);
      final rects = cardRects(tester);
      for (final r in rects) {
        _expectClearOfSpine(r, band, 'library card');
      }
      expect(rects.any((r) => r.right <= band.left), isTrue);
      expect(rects.any((r) => r.left >= band.right), isTrue);
      // Cards keep their size; only their position changes.
      expect(rects.map((r) => r.width).toSet(), {240.0});
      await _unmount(tester);
    });

    testWidgets('flat landscape keeps the ordinary rows (control: a card does cross the middle)', (tester) async {
      await pumpFavorites(tester, _innerLandscape, DuoPosture.fullyOpen);
      final band = _bandIfFolded(tester);
      expect(cardRects(tester).any((r) => _onSpine(r, band)), isTrue);
      expect(_onSpine(tester.getRect(find.widgetWithIcon(PlixButton, Icons.check_circle_rounded)), band), isTrue,
          reason: 'the bottom Save button is centred on the spine when flat');
      await _unmount(tester);
    });

    testWidgets('book: every button is off the spine and still works', (tester) async {
      await pumpFavorites(tester, _innerLandscape, DuoPosture.book);
      final band = _band(tester);
      final buttons = _rects(tester, find.byType(PlixButton));
      expect(buttons, hasLength(3), reason: 'Refresh, Save and the bottom Save');
      for (final r in buttons) {
        _expectClearOfSpine(r, band, 'button');
      }
      _expectClearOfSpine(tester.getRect(find.byIcon(Icons.arrow_back_rounded)), band, 'back');
      _expectClearOfSpine(tester.getRect(find.text('Favorite Libraries')), band, 'title');

      // A card on the far side of the spine still toggles.
      final right = _libraryTitles.firstWhere((t) => tester.getRect(_libraryCard(t)).left >= band.right);
      final before = find.byIcon(Icons.favorite_border_rounded).evaluate().length;
      await tester.tap(_libraryCard(right));
      await _settle(tester);
      expect(find.byIcon(Icons.favorite_border_rounded).evaluate().length, isNot(before));
      await _unmount(tester);
    });

    testWidgets('book: arrow keys follow the drawn columns across the spine', (tester) async {
      await pumpFavorites(tester, _innerLandscape, DuoPosture.book);
      final band = _band(tester);
      final rects = cardRects(tester);
      final columns = _firstRowCount(rects);
      FocusNode node(int i) => tester
          .widget<Focus>(find
              .ancestor(
                of: find.text(_libraryTitles[i]),
                matching: find.byWidgetPredicate((w) => w is Focus && w.onKeyEvent != null),
              )
              .first)
          .focusNode!;

      node(0).requestFocus();
      await tester.pump();
      for (var i = 1; i < columns; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await _settle(tester);
        expect(node(i).hasFocus, isTrue);
      }
      expect(rects[columns - 1].left, greaterThanOrEqualTo(band.right), reason: 'focus reached the right half');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      expect(node(2 * columns - 1).hasFocus, isTrue);
      expect(rects[2 * columns - 1].left, rects[columns - 1].left);
      await _unmount(tester);
    });

    testWidgets('book and tabletop: the loading state is kept out of the fold', (tester) async {
      await _setUp(tester, _innerLandscape, DuoPosture.book);
      final auth = PlexAuthService();
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => DuoScope(child: child!),
        // No cached libraries, so the spinner stays up while the (slow) fresh
        // fetch runs.
        home: FavoriteLibrariesScreen(
          authService: auth,
          serverService: PlexServerService(authService: auth),
          servers: [
            PlexServer(
              name: 'Jellyfin',
              clientIdentifier: 'jf_srv',
              accessToken: 'tok',
              owned: true,
              connections: [],
              activeConnectionUri: 'http://jf.test:8096',
              serverType: 'jellyfin',
            ),
          ],
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      final text = find.text('Loading libraries across all servers...');
      expect(text, findsOneWidget);
      _expectClearOfSpine(tester.getRect(text), _band(tester), 'loading text');
      _expectClearOfSpine(tester.getRect(find.text('Favorite Libraries')), _band(tester), 'title');

      tester.view.physicalSize = _innerPortrait;
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(text, findsOneWidget);
      _expectClearOfTabletopBand(tester.getRect(text), _band(tester), 'loading text');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 10));
      await _unmount(tester);
    });

    testWidgets('closed and flat lay out exactly like a non-Duo device', (tester) async {
      for (final size in [_cover, _innerPortrait, _innerLandscape]) {
        await pumpFavorites(tester, size, null);
        final plain = cardRects(tester);
        final plainButtons = _rects(tester, find.byType(PlixButton));
        final plainTitle = tester.getRect(find.text('Favorite Libraries'));
        for (final posture in [DuoPosture.closed, DuoPosture.fullyOpen]) {
          await _unmount(tester);
          await pumpFavorites(tester, size, posture);
          expect(cardRects(tester), plain, reason: '$posture at $size');
          expect(_rects(tester, find.byType(PlixButton)), plainButtons, reason: '$posture at $size');
          expect(tester.getRect(find.text('Favorite Libraries')), plainTitle, reason: '$posture at $size');
        }
        await _unmount(tester);
      }
    });

    testWidgets('tabletop keeps the portrait layout', (tester) async {
      await pumpFavorites(tester, _innerPortrait, null);
      final plain = cardRects(tester);
      final plainButtons = _rects(tester, find.byType(PlixButton));
      await _unmount(tester);
      await pumpFavorites(tester, _innerPortrait, DuoPosture.tabletop);
      expect(cardRects(tester), plain);
      expect(_rects(tester, find.byType(PlixButton)), plainButtons);
      await _unmount(tester);
    });

    testWidgets('no overflow or layout error in any pose', (tester) async {
      for (final (size, posture) in _poses) {
        await pumpFavorites(tester, size, posture);
        expect(tester.takeException(), isNull, reason: '$posture at $size');
        await _unmount(tester);
      }
    });
  });
}
