import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plix/app_theme.dart';
import 'package:plix/models/plex_pin.dart';
import 'package:plix/models/plex_server.dart';
import 'package:plix/models/plix_profile.dart';
import 'package:plix/screens/auth_chooser_screen.dart';
import 'package:plix/screens/jellyfin_connect_screen.dart';
import 'package:plix/screens/login_screen.dart';
import 'package:plix/screens/profile_setup_screen.dart';
import 'package:plix/screens/profiles_screen.dart';
import 'package:plix/screens/server_select_screen.dart';
import 'package:plix/screens/splash_screen.dart';
import 'package:plix/services/iphone_duo_service.dart';
import 'package:plix/services/plex_auth_service.dart';
import 'package:plix/services/plex_server_service.dart';
import 'package:plix/services/profile_service.dart';
import 'package:plix/widgets/brand_logo.dart';
import 'package:plix/widgets/custom_avatar_upload_dialog.dart';
import 'package:plix/widgets/duo_fold.dart';
import 'package:plix/widgets/pin_dialog.dart';
import 'package:plix/widgets/profile_avatar_widget.dart';

const _outer = Size(466, 678);
const _innerPortrait = Size(669, 951);
const _innerLandscape = Size(951, 669);

const _profilesJson = '['
    '{"id":"p1","name":"Home","avatarId":"avatar_default","avatarColorId":"gradient_gold","pin":"1234","hasPin":true,"createdAt":1700000000000},'
    '{"id":"p2","name":"Kids","avatarId":"avatar_cat","avatarColorId":"gradient_blue","pin":"","hasPin":false,"createdAt":1700000000000},'
    '{"id":"p3","name":"Guest Room","avatarId":"avatar_popcorn","avatarColorId":"gradient_gold","pin":"","hasPin":false,"createdAt":1700000000000},'
    '{"id":"p4","name":"Grandparents","avatarId":"avatar_default","avatarColorId":"gradient_blue","pin":"","hasPin":false,"createdAt":1700000000000}'
    ']';

/// Real glyph metrics. The default test font makes every glyph a full em
/// square, which overstates text widths and would report overflows the app
/// does not have.
Future<void> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  expect(root, isNotNull, reason: 'flutter test sets FLUTTER_ROOT');
  final loader = FontLoader('Roboto');
  for (final face in ['Regular', 'Medium', 'Bold', 'Black']) {
    final file = File('$root/bin/cache/artifacts/material_fonts/Roboto-$face.ttf');
    loader.addFont(file.readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await loader.load();
}

/// Hands the login screen a link code without touching the network.
class _FakeAuthService extends PlexAuthService {
  @override
  Future<PlexPin> createPin() async =>
      PlexPin(id: 1, code: 'AB12', clientIdentifier: 'test', expiresIn: 900);

  @override
  Future<PlexPin> checkPin(int pinId, String code) async =>
      PlexPin(id: 1, code: 'AB12', clientIdentifier: 'test', expiresIn: 900);
}

PlexServer _server(int i, {bool jellyfin = false}) => PlexServer(
      name: 'Server $i',
      clientIdentifier: 'srv$i',
      accessToken: 't',
      owned: true,
      connections: [],
      serverType: jellyfin ? 'jellyfin' : 'plex',
    );

Future<void> _pump(WidgetTester tester, Size size, Widget home) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: PlixTheme.themeData,
    builder: (context, child) => DuoScope(child: child!),
    home: home,
  ));
  // DuoAvoidFold measures itself after the first frame.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Unmounts the screen and lets its timers run out.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

DuoFold _fold(Size size) => IPhoneDuoService.currentInfo.foldFor(size)!;

bool _isSensitive(Widget w) =>
    w is RichText ||
    w is EditableText ||
    w is InkWell ||
    w is ButtonStyleButton ||
    w is IconButton ||
    w is Icon ||
    w is ProfileAvatarWidget ||
    w is QrImageView ||
    w is PlixAppLogo ||
    w is PinKeypadWidget ||
    w is ProgressIndicator;

/// The part of [element] that is actually on screen: its box clipped by every
/// scroll viewport above it.
Rect _visibleRect(Element element) {
  final box = element.renderObject! as RenderBox;
  var rect = box.localToGlobal(Offset.zero) & box.size;
  RenderObject? ancestor = box.parent;
  while (ancestor != null) {
    final RenderObject a = ancestor;
    if (a is RenderAbstractViewport && a is RenderBox) {
      Clip clip = Clip.hardEdge;
      try {
        clip = (a as dynamic).clipBehavior as Clip;
      } catch (_) {}
      if (clip != Clip.none) {
        final RenderBox viewport = a as RenderBox;
        rect = rect.intersect(viewport.localToGlobal(Offset.zero) & viewport.size);
      }
    }
    ancestor = ancestor.parent;
  }
  return rect;
}

/// Every piece of text, image and tap target under [scope] that touches the
/// fold band.
List<String> _inFold(WidgetTester tester, Rect band, {Finder? scope}) {
  final all = find.byWidgetPredicate(_isSensitive);
  final finder = scope == null ? all : find.descendant(of: scope, matching: all);
  final elements = finder.evaluate().toList();
  expect(elements, isNotEmpty, reason: 'nothing was checked');
  final offenders = <String>[];
  for (final e in elements) {
    final r = _visibleRect(e);
    if (r.width <= 0 || r.height <= 0) continue;
    if (r.overlaps(band)) offenders.add('${e.widget.toStringShort()} at $r');
  }
  return offenders;
}

void _expectClearOfFold(WidgetTester tester, Size size, {Finder? scope}) {
  expect(_inFold(tester, _fold(size).band, scope: scope), isEmpty);
}

/// Global rects of every text on screen, for before/after comparisons.
List<Rect> _textRects(WidgetTester tester) => [
      for (final e in find.byType(RichText).evaluate())
        (e.renderObject! as RenderBox).localToGlobal(Offset.zero) & (e.renderObject! as RenderBox).size,
    ];

typedef _ScreenBuilder = Widget Function();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadRoboto);

  late PlexAuthService authService;
  late PlexServerService serverService;

  setUp(() async {
    IPhoneDuoService.debugReset();
    SharedPreferences.setMockInitialValues({
      'plix_profiles_list': _profilesJson,
      'plix_active_profile_id': 'p1',
    });
    await ProfileService.instance.init();
    authService = _FakeAuthService();
    serverService = PlexServerService(authService: authService);
  });
  tearDown(IPhoneDuoService.debugReset);

  final screens = <String, _ScreenBuilder>{
    'ProfilesScreen': () => ProfilesScreen(authService: authService, serverService: serverService),
    'ProfileSetupScreen (new)': () =>
        ProfileSetupScreen(authService: authService, serverService: serverService),
    'ProfileSetupScreen (edit)': () => ProfileSetupScreen(
          authService: authService,
          serverService: serverService,
          profileToEdit: ProfileService.instance.profiles.first,
        ),
    'LoginScreen': () => LoginScreen(authService: authService, serverService: serverService),
    'AuthChooserScreen': () => AuthChooserScreen(
          authService: authService,
          serverService: serverService,
          isCreatingProfile: true,
        ),
    'JellyfinConnectScreen': () =>
        JellyfinConnectScreen(authService: authService, serverService: serverService),
    'ServerSelectScreen': () => ServerSelectScreen(
          servers: [for (var i = 0; i < 4; i++) _server(i, jellyfin: i.isOdd)],
          authService: authService,
          serverService: serverService,
        ),
    'ServerSelectScreen (one server)': () => ServerSelectScreen(
          servers: [_server(0)],
          authService: authService,
          serverService: serverService,
        ),
    'SplashScreen': () => SplashScreen(authService: authService, serverService: serverService),
  };

  group('half folded: nothing sits in the fold', () {
    for (final entry in screens.entries) {
      testWidgets('${entry.key} in book', (tester) async {
        await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
        await _pump(tester, _innerLandscape, entry.value());
        _expectClearOfFold(tester, _innerLandscape);
        await _dispose(tester);
      });

      testWidgets('${entry.key} in tabletop', (tester) async {
        await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
        await _pump(tester, _innerPortrait, entry.value());
        _expectClearOfFold(tester, _innerPortrait);
        await _dispose(tester);
      });
    }

    testWidgets('the check has teeth: laid flat, the centred layout does cross the middle', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(
        tester,
        _innerLandscape,
        AuthChooserScreen(authService: authService, serverService: serverService),
      );
      final middle = Rect.fromCenter(
        center: _innerLandscape.center(Offset.zero),
        width: IPhoneDuoInfo.defaultFoldBand,
        height: _innerLandscape.height,
      );
      expect(_inFold(tester, middle), isNotEmpty);
    });
  });

  group('half folded: every control stays reachable', () {
    testWidgets('all profiles and Add Profile can be scrolled to and tapped in book', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(
        tester,
        _innerLandscape,
        ProfilesScreen(authService: authService, serverService: serverService),
      );
      final band = _fold(_innerLandscape).band;
      for (final label in ['Home', 'Kids', 'Guest Room', 'Grandparents', 'Add Profile']) {
        await tester.ensureVisible(find.text(label));
        await tester.pump(const Duration(milliseconds: 400));
        expect(_visibleRect(find.text(label).evaluate().single).overlaps(band), isFalse);
        expect(tester.getRect(find.text(label)).right, lessThanOrEqualTo(band.left));
      }
      _expectClearOfFold(tester, _innerLandscape);
      await _dispose(tester);
    });

    testWidgets('both providers remain tappable in book and tabletop', (tester) async {
      for (final size in [_innerLandscape, _innerPortrait]) {
        await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
        await _pump(
          tester,
          size,
          AuthChooserScreen(authService: authService, serverService: serverService),
        );
        for (final label in ['Plex', 'Jellyfin']) {
          await tester.ensureVisible(find.text(label));
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text(label).hitTestable(), findsOneWidget);
        }
        _expectClearOfFold(tester, size);
        await _dispose(tester);
      }
    });

    testWidgets('profile setup: save and delete can be reached in tabletop', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      await _pump(
        tester,
        _innerPortrait,
        ProfileSetupScreen(
          authService: authService,
          serverService: serverService,
          profileToEdit: ProfileService.instance.profiles.first,
        ),
      );
      for (final label in ['Save Changes', 'Delete Profile']) {
        await tester.ensureVisible(find.text(label));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text(label).hitTestable(), findsOneWidget);
      }
      _expectClearOfFold(tester, _innerPortrait);
      await _dispose(tester);
    });

    testWidgets('profile setup: the form moves to the upper half while the keyboard is up in tabletop',
        (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      await _pump(
        tester,
        _innerPortrait,
        ProfileSetupScreen(authService: authService, serverService: serverService),
      );
      final band = _fold(_innerPortrait).band;
      expect(tester.getRect(find.text('PROFILE NAME')).top, greaterThanOrEqualTo(band.bottom));

      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getRect(find.text('PROFILE NAME')).bottom, lessThanOrEqualTo(band.top));
      _expectClearOfFold(tester, _innerPortrait);
      await _dispose(tester);
    });
  });

  group('dialogs fit inside one half', () {
    Future<BuildContext> host(WidgetTester tester, Size size) async {
      late BuildContext ctx;
      await _pump(tester, size, Scaffold(body: Builder(builder: (context) {
        ctx = context;
        return const SizedBox.expand();
      })));
      return ctx;
    }

    final profile = PlixProfile.fromJson(const {
      'id': 'p1',
      'name': 'Home',
      'avatarId': 'avatar_default',
      'avatarColorId': 'gradient_gold',
      'pin': '1234',
      'hasPin': true,
      'createdAt': 1700000000000,
    });

    Rect card(WidgetTester tester, Type dialog) => tester.getRect(
          find.descendant(of: find.byType(dialog), matching: find.byType(Container)).first,
        );

    testWidgets('PIN dialog: lower half in tabletop, full-size keys, wrong PIN error fits', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      final ctx = await host(tester, _innerPortrait);
      final result = PinDialog.show(ctx, profile);
      await tester.pumpAndSettle();
      final band = _fold(_innerPortrait).band;

      expect(card(tester, PinDialog).top, greaterThanOrEqualTo(band.bottom));
      expect(card(tester, PinDialog).bottom, lessThanOrEqualTo(_innerPortrait.height));
      _expectClearOfFold(tester, _innerPortrait, scope: find.byType(PinDialog));
      // Not scaled down: the keys keep their designed size.
      expect(tester.getSize(find.text('5')).height, greaterThan(0));
      final key5 = tester.getRect(
        find.ancestor(of: find.text('5'), matching: find.byType(InkWell)).first,
      );
      expect(key5.size, const Size(62, 44));

      for (final d in ['9', '9', '9', '9']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      expect(find.text('Incorrect PIN. Please try again.'), findsOneWidget);
      expect(card(tester, PinDialog).top, greaterThanOrEqualTo(band.bottom));
      expect(card(tester, PinDialog).bottom, lessThanOrEqualTo(_innerPortrait.height));

      for (final d in ['1', '2', '3', '4']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(await result, isTrue);
    });

    testWidgets('PIN dialog: left half in book', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      final ctx = await host(tester, _innerLandscape);
      PinDialog.show(ctx, profile);
      await tester.pumpAndSettle();
      final band = _fold(_innerLandscape).band;
      final rect = card(tester, PinDialog);
      expect(rect.right, lessThanOrEqualTo(band.left));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(_innerLandscape.height));
      _expectClearOfFold(tester, _innerLandscape, scope: find.byType(PinDialog));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(PinDialog), findsNothing);
    });

    testWidgets('PIN setup dialog fits one half in tabletop and book and returns the PIN', (tester) async {
      for (final size in [_innerPortrait, _innerLandscape]) {
        await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
        final ctx = await host(tester, size);
        final result = PinSetupDialog.show(ctx);
        await tester.pumpAndSettle();
        final rect = card(tester, PinSetupDialog);
        expect(rect.overlaps(_fold(size).band), isFalse);
        expect((Offset.zero & size).contains(rect.topLeft), isTrue);
        expect((Offset.zero & size).contains(rect.bottomRight), isTrue);
        _expectClearOfFold(tester, size, scope: find.byType(PinSetupDialog));
        for (final d in ['4', '3', '2', '1']) {
          await tester.tap(find.text(d));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(await result, '4321');
      }
    });

    testWidgets('PIN dialog shrinks instead of overflowing when a half is smaller than it', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      tester.view.padding = const FakeViewPadding(top: 60, bottom: 220);
      final ctx = await host(tester, _innerPortrait);
      PinDialog.show(ctx, profile);
      await tester.pumpAndSettle();
      final band = _fold(_innerPortrait).band;
      final rect = card(tester, PinDialog);
      expect(rect.top, greaterThanOrEqualTo(band.bottom));
      expect(rect.bottom, lessThanOrEqualTo(_innerPortrait.height - 220));
      await tester.tap(find.text('7'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(PinDialog), findsNothing);
    });

    testWidgets('PIN dialogs are unchanged when flat, closed or not a Duo', (tester) async {
      Future<Rect> measure(DuoPosture? posture, Size size) async {
        IPhoneDuoService.debugReset();
        if (posture != null) await IPhoneDuoService.setSimulatedPosture(posture);
        final ctx = await host(tester, size);
        PinDialog.show(ctx, profile);
        await tester.pumpAndSettle();
        expect(find.byType(FittedBox), findsNothing);
                final rect = card(tester, PinDialog);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        return rect;
      }

      for (final size in [_outer, _innerPortrait, _innerLandscape]) {
        final plain = await measure(null, size);
        expect(plain.width, 360);
        expect(plain.center.dx, closeTo(size.width / 2, 0.01));
        expect(plain.center.dy, closeTo(size.height / 2, 0.01));
        expect(await measure(DuoPosture.fullyOpen, size), plain);
        expect(await measure(DuoPosture.closed, size), plain);
      }
    });

    testWidgets('custom avatar dialog fits one half and is not squeezed by the keyboard in tabletop',
        (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.tabletop);
      final ctx = await host(tester, _innerPortrait);
      CustomAvatarUploadDialog.show(ctx);
      await tester.pumpAndSettle();
      final band = _fold(_innerPortrait).band;
      Rect dialogCard() => tester.getRect(find
          .descendant(of: find.byType(CustomAvatarUploadDialog), matching: find.byType(Container))
          .first);
      final before = dialogCard();
      expect(before.bottom, lessThanOrEqualTo(band.top));
      expect(before.top, greaterThanOrEqualTo(0));
      _expectClearOfFold(tester, _innerPortrait, scope: find.byType(CustomAvatarUploadDialog));

      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      await tester.pumpAndSettle();
      final after = dialogCard();
      expect(after.size, before.size);
      expect(after.bottom, lessThanOrEqualTo(band.top));
      expect(after.top, greaterThanOrEqualTo(0));
      expect(find.text('Apply').hitTestable(), findsOneWidget);
    });

    testWidgets('custom avatar dialog fits the left half in book', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      final ctx = await host(tester, _innerLandscape);
      CustomAvatarUploadDialog.show(ctx);
      await tester.pumpAndSettle();
      final band = _fold(_innerLandscape).band;
      final rect = tester.getRect(find
          .descendant(of: find.byType(CustomAvatarUploadDialog), matching: find.byType(Container))
          .first);
      expect(rect.right, lessThanOrEqualTo(band.left));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(_innerLandscape.height));
      _expectClearOfFold(tester, _innerLandscape, scope: find.byType(CustomAvatarUploadDialog));
    });

    testWidgets('remove-server confirmation stays on one side in book', (tester) async {
      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await _pump(
        tester,
        _innerLandscape,
        ServerSelectScreen(
          servers: [_server(0, jellyfin: true)],
          authService: authService,
          serverService: serverService,
        ),
      );
      await tester.longPress(find.text('Server 0'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      _expectClearOfFold(tester, _innerLandscape, scope: find.byType(AlertDialog));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await _dispose(tester);
    });
  });

  group('flat, closed and non-Duo layouts', () {
    for (final entry in screens.entries) {
      testWidgets('${entry.key}: no overflow at Duo sizes, and identical to a non-Duo device', (tester) async {
        for (final size in [_outer, _innerPortrait, _innerLandscape]) {
          // The three-column server grid overflows its cards by 8pt on every
          // wide device today; only the Duo's inner display gets taller cards,
          // so that one layout is compared separately below.
          final knownGridOverflow = entry.key.startsWith('ServerSelectScreen') && size == _innerLandscape;

          IPhoneDuoService.debugReset();
          await _pump(tester, size, entry.value());
          if (knownGridOverflow) {
            while (tester.takeException() != null) {}
          }
          expect(find.byType(DuoFoldBuilder), findsNothing);
          final plain = _textRects(tester);
          expect(plain, isNotEmpty);
          await _dispose(tester);

          for (final posture in [DuoPosture.fullyOpen, DuoPosture.closed]) {
            await IPhoneDuoService.setSimulatedPosture(posture);
            await _pump(tester, size, entry.value());
            expect(find.byType(DuoFoldBuilder), findsNothing);
            if (knownGridOverflow && posture == DuoPosture.fullyOpen) {
              expect(
                [for (final r in _textRects(tester)) (r.left, r.right)],
                [for (final r in plain) (r.left, r.right)],
              );
            } else {
              if (knownGridOverflow) {
                while (tester.takeException() != null) {}
              }
              expect(_textRects(tester), plain);
            }
            await _dispose(tester);
          }
        }
      });
    }

    testWidgets('unfolding from book puts the content back across the full width', (tester) async {
      // Horizontal extents only: focus highlights can differ by a point or
      // two vertically after the round trip.
      List<(double, double)> spans() => [for (final r in _textRects(tester)) (r.left, r.right)];

      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await _pump(
        tester,
        _innerLandscape,
        ServerSelectScreen(
          servers: [for (var i = 0; i < 4; i++) _server(i)],
          authService: authService,
          serverService: serverService,
        ),
      );
      final flat = spans();

      await IPhoneDuoService.setSimulatedPosture(DuoPosture.book);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _expectClearOfFold(tester, _innerLandscape);
      expect(spans(), isNot(flat));

      await IPhoneDuoService.setSimulatedPosture(DuoPosture.fullyOpen);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(spans(), flat);
      await _dispose(tester);
    });

    testWidgets('typed text and keyboard focus survive folding and unfolding', (tester) async {
      await _pump(
        tester,
        _innerPortrait,
        JellyfinConnectScreen(authService: authService, serverService: serverService),
      );
      await tester.enterText(find.byType(EditableText), '10.0.0.50:8096');
      await tester.pump();
      final state = tester.state(find.byType(EditableText));
      expect(tester.testTextInput.hasAnyClients, isTrue);

      for (final posture in [DuoPosture.tabletop, DuoPosture.fullyOpen]) {
        await IPhoneDuoService.setSimulatedPosture(posture);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('10.0.0.50:8096'), findsOneWidget);
        expect(tester.state(find.byType(EditableText)), same(state));
        expect(tester.testTextInput.hasAnyClients, isTrue);
      }
      await _dispose(tester);
    });
  });
}
