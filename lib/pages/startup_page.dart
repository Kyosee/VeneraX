import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/init.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/pages/onboarding_page.dart';
import 'package:venera/pages/onboarding_style.dart';
import 'package:venera/utils/translations.dart';
import 'package:window_manager/window_manager.dart';

class StartupPage extends StatefulWidget {
  const StartupPage({super.key});
  @override
  State<StartupPage> createState() => _StartupPageState();
}

class _StartupPageState extends State<StartupPage> {
  final _store = OnboardingStore.instance;
  late bool _unlocked;
  bool _servicesReady = false;
  bool _interactiveStarted = false;
  bool _declined = false;
  Future<void>? _initializing;

  @override
  void initState() {
    super.initState();
    _unlocked = appdata.settings['authorizationRequired'] != true;
    AuthPage.isActive = !_unlocked;
    if (_unlocked &&
        _store.loadError == null &&
        _store.state.setupCompleted &&
        !_store.state.needsAgreement()) {
      unawaited(_ensureServices());
    }
  }

  Future<void> _ensureServices() => _initializing ??= () async {
    if (!_store.state.setupCompleted &&
        appdata.settings['webdav'] is List &&
        (appdata.settings['webdav'] as List).isEmpty) {
      appdata.implicitData['webdavAutoSync'] = false;
      appdata.implicitData['webdavSyncMode'] = 'manual';
    }
    await initDeferred();
    if (mounted) setState(() => _servicesReady = true);
  }();

  Future<void> _acceptUpdate() async {
    await _store.accept(agreementReadingLanguage());
    if (mounted) setState(() {});
    await _ensureServices();
  }

  void _decline() {
    setState(() => _declined = true);
    if (App.isDesktop) {
      unawaited(windowManager.destroy());
    } else if (App.isAndroid || App.isOhos) {
      unawaited(SystemNavigator.pop());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_store.loadError != null) {
      return _message(
        'Unable to read the setup record. Check available storage and retry.',
        'Retry',
        () async {
          await _store.load(App.dataPath);
          if (!mounted) return;
          setState(() {});
          if (_unlocked &&
              _store.loadError == null &&
              _store.state.setupCompleted &&
              !_store.state.needsAgreement()) {
            unawaited(_ensureServices());
          }
        },
      );
    }
    if (!_unlocked) {
      return AuthPage(
        onSuccessfulAuth: () {
          AuthPage.isActive = false;
          setState(() => _unlocked = true);
          if (_store.state.setupCompleted && !_store.state.needsAgreement()) {
            unawaited(_ensureServices());
          }
        },
      );
    }
    if (_declined) {
      return _message(
        'The agreement has not been accepted. Your existing data is preserved.',
        'Back to the agreement',
        () => setState(() => _declined = false),
      );
    }
    if (!_store.state.setupCompleted) {
      return OnboardingPage(
        ensureServices: _ensureServices,
        onFinished: () => setState(() {}),
        onDeclined: _decline,
      );
    }
    if (_store.state.needsAgreement()) {
      return OnboardingTheme(
        builder: (context) => PopScope(
          canPop: false,
          child: Scaffold(
            body: SafeArea(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ExcludeSemantics(child: _HomeBackdrop()),
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                    child: ColoredBox(
                      color: const Color(0xff13233c).withValues(alpha: .4),
                    ),
                  ),
                  LayoutBuilder(
                    builder: (context, size) => Center(
                      child: Padding(
                        padding: EdgeInsets.all(size.maxWidth < 600 ? 10 : 28),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 700),
                          child: Material(
                            elevation: 12,
                            borderRadius: BorderRadius.circular(
                              size.maxWidth < 600 ? 17 : 18,
                            ),
                            color: Theme.of(context).colorScheme.surface,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: size.maxWidth < 600 ? 17 : 26,
                                vertical: size.maxWidth < 600 ? 18 : 22,
                              ),
                              child: AgreementPanel(
                                isUpdate: true,
                                previousVersion: _store.state.acceptedVersion,
                                onAccepted: _acceptUpdate,
                                onDeclined: _decline,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (!_servicesReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_interactiveStarted) {
      _interactiveStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) startInteractiveServices();
      });
    }
    return const MainPage();
  }

  Widget _message(String message, String action, VoidCallback callback) =>
      Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.description_outlined, size: 48),
                  const SizedBox(height: 20),
                  Text(message.tl, textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  FilledButton(onPressed: callback, child: Text(action.tl)),
                ],
              ),
            ),
          ),
        ),
      );
}

/// The shell gives context without mounting pages that start network work.
class _HomeBackdrop extends StatelessWidget {
  const _HomeBackdrop();
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, size) {
        const destinations = ['Home', 'Favorites', 'Explore', 'Categories'];
        const icons = [
          Icons.home_outlined,
          Icons.bookmark_outline,
          Icons.explore_outlined,
          Icons.category_outlined,
        ];
        final body = Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Home'.tl,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 40),
              for (final label in [
                'History',
                'Local',
                'Follow updates',
                'Comic Sources',
                'Image Favorites',
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Text(
                    label.tl,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
            ],
          ),
        );
        if (size.maxWidth < 840) return body;
        return Row(
          children: [
            Container(
              width: 230,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Text(
                    'VeneraX',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 36),
                  for (var i = 0; i < destinations.length; i++)
                    ListTile(
                      leading: Icon(icons[i]),
                      title: Text(destinations[i].tl),
                    ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        );
      },
    ),
  );
}
