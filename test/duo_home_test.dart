import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plix/models/plex_library.dart';
import 'package:plix/models/plex_media_item.dart';
import 'package:plix/models/plex_server.dart';
import 'package:plix/screens/home_screen.dart';
import 'package:plix/services/iphone_duo_service.dart';
import 'package:plix/services/plex_auth_service.dart';
import 'package:plix/services/plex_server_service.dart';
import 'package:plix/services/plix_device_helper.dart';
import 'package:plix/widgets/duo_fold.dart';
import 'package:plix/widgets/plix_bottom_nav.dart';
import 'package:plix/widgets/plix_button.dart';
import 'package:plix/widgets/sidebar_nav.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _cover = Size(466, 678);
const _innerPortrait = Size(669, 951);
const _innerLandscape = Size(951, 669);

const _heroSummary =
    'A deliberately long synopsis that would run well past the middle of a wide screen if nothing '
    'held it back, so that the test can tell whether the hero block is kept clear of the fold.';
const _heroTitle = 'An Extremely Long Feature Film Title That Keeps On Going';
const _rowTitle = 'Recently Added in A Library With A Remarkably Long Name For A Row Heading';

final _server = PlexServer(
  name: 'Test Server',
  clientIdentifier: 'srv_1',
  accessToken: 'tok',
  owned: true,
  connections: [],
);

PlexMediaItem _item(int i, {String? title}) => PlexMediaItem(
      ratingKey: 'rk$i',
      key: '/library/metadata/rk$i',
      title: title ?? 'Item $i',
      type: 'movie',
      summary: _heroSummary,
      year: 2024,
      duration: 7200000,
      contentRating: 'PG-13',
    );

final _library = PlexLibrary(
  key: '1',
  title: 'A Library With A Remarkably Long Name For A Row Heading',
  type: 'movie',
);

HomeDebugContent _content() => HomeDebugContent(
      libraries: [_library],
      continueWatching: [
        _item(0, title: _heroTitle),
        for (var i = 1; i < 12; i++) _item(i),
      ],
      recentlyAdded: {
        _library.compositeId: [for (var i = 20; i < 32; i++) _item(i)],
      },
    );

Rect _band(Size size) => IPhoneDuoService.currentInfo.foldFor(size)!.band;

Future<void> _pump(WidgetTester tester, Size size, Widget home) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => DuoScope(child: child!),
    home: home,
  ));
  // Lets the fold be measured and the post-frame checks of the screen run.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _home({bool offline = false}) {
  final auth = PlexAuthService();
  return HomeScreen(
    server: _server,
    authService: auth,
    serverService: PlexServerService(authService: auth),
    isOfflineInitial: offline,
    debugContent: offline ? null : _content(),
  );
}

Widget _sidebar({List<PlexLibrary> libraries = const []}) => Scaffold(
      body: Row(children: [
        SidebarNav(
          currentServer: _server,
          libraries: libraries,
          activeDestination: NavDestination.home,
          onDestinationSelected: (_) {},
          onLibrarySelected: (_) {},
          onSwitchServer: () {},
          onSignOut: () {},
        ),
      ]),
    );

Future<void> _hoverSidebar(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: const Offset(900, 600));
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byType(SidebarNav)));
  await tester.pumpAndSettle();
}

/// Every rect the finder matches, failing if it matches nothing.
List<Rect> _rects(WidgetTester tester, Finder finder) {
  expect(finder, findsWidgets);
  return [for (final e in finder.evaluate()) tester.getRect(find.byWidget(e.widget))];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The helper assumes a television until the platform has been identified.
  setUpAll(PlixDeviceHelper.initDeviceName);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IPhoneDuoService.debugReset();
  });
  tearDown(IPhoneDuoService.debugReset);

  group('flat and closed', () {
    for (final entry in {
      'cover 466x678': (_cover, DuoPosture.closed),
      'inner portrait 669x951': (_innerPortrait, DuoPosture.fullyOpen),
      'inner landscape 951x669': (_innerLandscape, DuoPosture.fullyOpen),
    }.entries) {
      testWidgets('home with content does not overflow on ${entry.key}', (tester) async {
        await IPhoneDuoService.setSimulatedPosture(entry.value.$2);
        await _pump(tester, entry.value.$1, _home());
        expect(tester.takeException(), isNull);
        expect(find.text('Continue Watching'), findsOneWidget);
      });

      testWidgets('offline home does not overflow on ${entry.key}', (tester) async {
        await IPhoneDuoService.setSimulatedPosture(entry.value.$2);
        await _pump(tester, entry.value.$1, _home(offline: true));
        expect(tester.takeException(), isNull);
        expect(find.text('Retry'), findsOneWidget);
      });
    }

    testWidgets('the wide layout is sensibly proportioned at 951x669', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(tester, _innerLandscape, _home());
      expect(find.byType(SidebarNav), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsNothing);
      // The pinned hero leaves most of the height to the rows, and the first
      // rail is fully on screen.
      final summary = tester.getRect(find.text(_heroSummary));
      expect(summary.bottom, lessThan(_innerLandscape.height * 0.4));
      final firstRow = tester.getRect(find.text('Continue Watching'));
      expect(firstRow.top, greaterThan(summary.bottom));
      expect(firstRow.bottom + 245, lessThan(_innerLandscape.height));
    });

    testWidgets('the compact layout is used at 669x951 and 466x678', (tester) async {
      for (final size in [_innerPortrait, _cover]) {
        await IPhoneDuoService.setSimulatedPosture(
            size == _cover ? DuoPosture.closed : DuoPosture.fullyOpen);
        await _pump(tester, size, _home());
        expect(find.byType(SidebarNav), findsNothing);
        expect(find.byType(BottomNavigationBar), findsOneWidget);
        expect(tester.takeException(), isNull);
        // The featured card spans the width and is a modest share of the height.
        final watch = tester.getRect(find.text('Watch Now'));
        expect(watch.bottom, lessThan(size.height * 0.6));
      }
    });

    testWidgets('a flat Duo lays out exactly like any other device', (tester) async {
      Future<Map<String, Rect>> measure() async {
        await _pump(tester, _innerLandscape, _home());
        return {
          'summary': tester.getRect(find.text(_heroSummary)),
          'row': tester.getRect(find.textContaining(_rowTitle, findRichText: true)),
          'seeAll': tester.getRect(find.text('See all')),
          'sidebar': tester.getRect(find.byType(SidebarNav)),
        };
      }

      final other = await measure();
      await tester.pumpWidget(const SizedBox());
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      final flat = await measure();
      expect(flat, other);
      // Unfolded, the hero is free to run past the middle of the screen.
      expect(other['summary']!.right, greaterThan(_innerLandscape.width / 2));
    });
  });

  group('book', () {
    setUp(() => IPhoneDuoService.setSimulatedPosture(DuoPosture.book));

    testWidgets('the hero block stays left of the spine', (tester) async {
      await _pump(tester, _innerLandscape, _home());
      expect(tester.takeException(), isNull);
      final band = _band(_innerLandscape);

      final summary = tester.getRect(find.text(_heroSummary));
      expect(summary.right, lessThanOrEqualTo(band.left));
      expect(summary.width, greaterThan(200));

      final heroTitle = find.byWidgetPredicate(
          (w) => w is Text && w.data == _heroTitle && w.style?.fontSize == 32);
      expect(tester.getRect(heroTitle).right, lessThanOrEqualTo(band.left));

      for (final label in ['2024', 'PG-13']) {
        for (final rect in _rects(tester, find.text(label))) {
          if (rect.top < summary.top) {
            expect(rect.right, lessThanOrEqualTo(band.left), reason: label);
          }
        }
      }
    });

    testWidgets('row headings end before the spine and See all stays clear of it', (tester) async {
      await _pump(tester, _innerLandscape, _home());
      final band = _band(_innerLandscape);

      final heading = tester.getRect(find.textContaining(_rowTitle, findRichText: true));
      expect(heading.right, lessThanOrEqualTo(band.left));
      expect(heading.width, greaterThan(200));

      final seeAll = tester.getRect(find.text('See all'));
      expect(seeAll.overlaps(band), isFalse);
      expect(seeAll.left, greaterThan(band.right));
    });

    testWidgets('the sidebar is clear of the spine collapsed and expanded (as it is flat)', (tester) async {
      await _pump(tester, _innerLandscape, _home());
      final band = _band(_innerLandscape);
      expect(tester.getRect(find.byType(SidebarNav)).right, lessThan(band.left));

      await _hoverSidebar(tester);
      final expanded = tester.getRect(find.byType(SidebarNav));
      expect(expanded.width, 245);
      expect(expanded.right, lessThan(band.left));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the offline message and its buttons sit left of the spine', (tester) async {
      await _pump(tester, _innerLandscape, _home(offline: true));
      expect(tester.takeException(), isNull);
      final band = _band(_innerLandscape);
      final buttons = _rects(tester, find.byType(PlixButton));
      expect(buttons, hasLength(2));
      for (final rect in buttons) {
        expect(rect.right, lessThanOrEqualTo(band.left));
        // Still to the right of the sidebar, not underneath it.
        expect(rect.left, greaterThan(tester.getRect(find.byType(SidebarNav)).right));
      }
      expect(tester.getRect(find.text('You are offline')).right, lessThanOrEqualTo(band.left));
    });

    testWidgets('the offline-server toast is not centred on the spine', (tester) async {
      final offlineLibrary = PlexLibrary(
        key: '9',
        title: 'Films',
        type: 'movie',
        serverName: 'Attic',
        isServerOnline: false,
      );
      await _pump(tester, _innerLandscape, _sidebar(libraries: [offlineLibrary]));
      await _hoverSidebar(tester);
      await tester.tap(find.text('Films (Offline)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final band = _band(_innerLandscape);
      final toast = tester.getRect(find.text('Attic is currently offline.'));
      expect(toast.overlaps(band), isFalse);
      expect(toast.right, lessThanOrEqualTo(band.left));
      expect(toast.left, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    });
  });

  group('tabletop', () {
    setUp(() => IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop));

    testWidgets('fixed chrome is clear of the fold (as it is flat) and the content scrolls through it',
        (tester) async {
      await _pump(tester, _innerPortrait, _home());
      expect(tester.takeException(), isNull);
      final band = _band(_innerPortrait);

      final nav = tester.getRect(find.byType(BottomNavigationBar));
      expect(nav.top, greaterThan(band.bottom));
      expect(tester.getRect(find.text('Customize Servers')).bottom, lessThan(band.top));

      // Whatever is in the band can be scrolled out of it.
      final before = tester.getRect(find.text('Continue Watching'));
      await tester.drag(find.text('Continue Watching'), const Offset(0, -120));
      await tester.pump();
      expect(tester.getRect(find.text('Continue Watching')).top, lessThan(before.top));
    });

    testWidgets('the offline message and its buttons use the lower half', (tester) async {
      await _pump(tester, _innerPortrait, _home(offline: true));
      expect(tester.takeException(), isNull);
      final band = _band(_innerPortrait);
      final nav = tester.getRect(find.byType(BottomNavigationBar));
      final buttons = _rects(tester, find.byType(PlixButton));
      expect(buttons, hasLength(2));
      for (final rect in buttons) {
        expect(rect.top, greaterThanOrEqualTo(band.bottom));
        expect(rect.bottom, lessThanOrEqualTo(nav.top));
      }
      expect(tester.getRect(find.text('You are offline')).top, greaterThanOrEqualTo(band.bottom));
    });

    testWidgets('the libraries sheet opens in the lower half', (tester) async {
      final libraries = [
        for (var i = 0; i < 12; i++) PlexLibrary(key: '$i', title: 'Library $i', type: 'movie'),
      ];
      await _pump(
        tester,
        _innerPortrait,
        Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: PlixBottomNav(
            currentIndex: 0,
            server: _server,
            clientId: 'client',
            libraries: libraries,
          ),
        ),
      );
      await tester.tap(find.text('Libraries'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final band = _band(_innerPortrait);
      expect(tester.getRect(find.byType(BottomSheet)).top, greaterThanOrEqualTo(band.bottom));
      expect(tester.getRect(find.text('Library 0')).top, greaterThanOrEqualTo(band.bottom));
    });
  });

  group('PlixBottomNav', () {
    for (final size in [_cover, _innerPortrait]) {
      testWidgets('lays its five items out evenly at ${size.width.toInt()} wide', (tester) async {
        await IPhoneDuoService.setSimulatedPosture(
            size == _cover ? DuoPosture.closed : DuoPosture.tabletop);
        await _pump(
          tester,
          size,
          Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: PlixBottomNav(currentIndex: 0, server: _server, clientId: 'client'),
          ),
        );
        expect(tester.takeException(), isNull);

        final bar = tester.getRect(find.byType(BottomNavigationBar));
        expect(bar.width, size.width);
        expect(bar.bottom, size.height);

        final labels = ['Home', 'Watchlist', 'Search', 'Libraries', 'Settings'];
        final slot = size.width / labels.length;
        for (var i = 0; i < labels.length; i++) {
          final rect = tester.getRect(find.text(labels[i]));
          expect(rect.left, greaterThanOrEqualTo(slot * i));
          expect(rect.right, lessThanOrEqualTo(slot * (i + 1)));
          expect(rect.center.dx, closeTo(slot * (i + 0.5), 1.0));
        }
      });
    }
  });
}
