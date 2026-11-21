import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plix/main.dart';
import 'package:plix/screens/splash_screen.dart';
import 'package:plix/services/iphone_duo_service.dart';
import 'package:plix/services/plex_auth_service.dart';
import 'package:plix/services/plex_server_service.dart';
import 'package:plix/widgets/duo_fold.dart';

void main() {
  testWidgets('PlixApp smoke test', (WidgetTester tester) async {
    final authService = PlexAuthService();
    final serverService = PlexServerService(authService: authService);

    await tester.pumpWidget(PlixApp(
      authService: authService,
      serverService: serverService,
    ));

    expect(find.byType(PlixApp), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('PlixApp installs DuoScope and publishes the fold of a half folded iPhone Duo', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(951, 669);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(IPhoneDuoService.debugReset);

    final authService = PlexAuthService();
    final serverService = PlexServerService(authService: authService);
    await tester.pumpWidget(PlixApp(
      authService: authService,
      serverService: serverService,
    ));

    expect(find.byType(DuoScope), findsOneWidget);
    BuildContext screen() => tester.element(find.byType(SplashScreen));

    // Not a Duo: nothing is added.
    expect(MediaQuery.of(screen()).displayFeatures, isEmpty);
    expect(IPhoneDuoService.postureOf(screen()), DuoPosture.none);

    // The hinge half opens while the app is running.
    IPhoneDuoService.updateFromNative({
      'isDuo': true,
      'hinge': 'partiallyOpen',
      'angle': 1.6,
      'inner': true,
      'landscape': true,
    });
    await tester.pump();
    final features = MediaQuery.of(screen()).displayFeatures;
    expect(features, hasLength(1));
    expect(features.single.type, ui.DisplayFeatureType.hinge);
    expect(features.single.state, ui.DisplayFeatureState.postureHalfOpened);
    expect(features.single.bounds, const Rect.fromLTRB(455.5, 0, 495.5, 669));
    expect(IPhoneDuoService.postureOf(screen()), DuoPosture.book);

    // Laid flat again: the fold reserves nothing.
    IPhoneDuoService.updateFromNative({
      'isDuo': true,
      'hinge': 'fullyOpen',
      'angle': 3.14,
      'inner': true,
      'landscape': true,
    });
    await tester.pump();
    expect(MediaQuery.of(screen()).displayFeatures, isEmpty);
    expect(IPhoneDuoService.postureOf(screen()), DuoPosture.fullyOpen);

    await tester.pump(const Duration(seconds: 2));
  });
}
