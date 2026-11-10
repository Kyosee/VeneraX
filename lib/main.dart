import 'dart:async';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/startup_page.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:window_manager/window_manager.dart';
import 'components/app_slider_theme.dart';
import 'components/components.dart';
import 'components/window_frame.dart';
import 'foundation/app.dart';
import 'foundation/appdata.dart';
import 'foundation/launcher_icon.dart';
import 'foundation/ohos_follow_worker.dart';
import 'foundation/download_keepalive.dart';
import 'foundation/shortcuts.dart';
import 'foundation/tray.dart';
import 'headless.dart';
import 'init.dart';

@pragma('vm:entry-point')
void followUpdatesBackgroundMain(List<String> args) => runOhosFollowWorker(args);

void main(List<String> args) {
  if (args.contains('--headless')) {
    runHeadlessMode(args);
    return;
  }
  if (runWebViewTitleBarWidget(args)) return;
  overrideIO(() {
    runZonedGuarded(() async {
      WidgetsFlutterBinding.ensureInitialized();
      try {
        await init();
      } on PlatformException catch (error) {
        if (error.code != 'FOLLOW_SCHEDULE_UNAVAILABLE') rethrow;
        await AppTranslation.init();
        // This screen must not initialize or read shared application stores.
        runApp(MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          home: Scaffold(body: SafeArea(child: Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Unable to access app data. Close and reopen VeneraX to retry.'.tl),
              TextButton(onPressed: SystemNavigator.pop, child: Text('Close'.tl)),
            ]),
          )))),
        ));
        return;
      }
      runApp(const MyApp());
      if (App.isDesktop) {
        await windowManager.ensureInitialized();
        AppShortcuts.install();
        windowManager.waitUntilReadyToShow().then((_) async {
          await windowManager.setTitleBarStyle(
            TitleBarStyle.hidden,
            windowButtonVisibility: App.isMacOS,
          );
          if (App.isLinux) {
            await windowManager.setBackgroundColor(Colors.transparent);
          }
          await windowManager.setMinimumSize(const Size(500, 600));
          var placement = await WindowPlacement.loadFromFile();
          if (App.isLinux) {
            await windowManager.show();
            await placement.applyToWindow();
          } else {
            await placement.applyToWindow();
            await windowManager.show();
          }

          WindowPlacement.loop();
          await TrayController.instance.init();
          await GlobalHotkeys.sync();
          // WM_SETICON is per-process; re-apply the stored icon each launch so
          // the window/taskbar icon follows the user's choice (issue #134).
          await LauncherIconService.applyForStartup();
        });
      }
    }, (error, stack) {
      Log.error("Unhandled Exception", error, stack);
    });
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    App.registerForceRebuild(forceRebuild);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addObserver(this);
    syncOhosStartupTheme();
    syncReaderNightModeWithSystem(rebuild: false);
    super.initState();
  }

  OverlayEntry? hideContentOverlay;
  String? _ohosThemeMode;

  void syncOhosStartupTheme() {
    if (!App.isOhos) return;
    final mode = switch (appdata.settings['theme_mode']) {
      'light' => 'light',
      'dark' => 'dark',
      _ => 'system',
    };
    if (_ohosThemeMode == mode) return;
    _ohosThemeMode = mode;
    unawaited(const MethodChannel('venera/method_channel')
        .invokeMethod<void>('setThemeMode', mode)
        .catchError((Object error) {
      if (_ohosThemeMode == mode) _ohosThemeMode = null;
      Log.warning('Theme', 'Unable to synchronize the startup theme.');
    }));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && App.isMobile) {
      DownloadKeepAlive.instance.onResume();
    }
    // Logs are buffered and flushed on a timer to avoid a disk write per
    // network request; push them out now, before the process can be suspended
    // or killed with lines still in memory. Must stay above the early return
    // below, which skips everything when app-lock is off.
    if (state != AppLifecycleState.resumed) {
      Log.flush();
      if (App.isOhos && App.local.isInitialized) {
        unawaited(App.local.saveCurrentDownloadingTasks());
      }
    }
    if (!App.isMobile || !appdata.settings['authorizationRequired']) {
      return;
    }
    if (state == AppLifecycleState.inactive && hideContentOverlay == null) {
      hideContentOverlay = OverlayEntry(
        builder: (context) {
          return Positioned.fill(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: App.rootContext.colorScheme.surface,
            ),
          );
        },
      );
      Overlay.of(App.rootContext).insert(hideContentOverlay!);
    } else if (hideContentOverlay != null &&
        state == AppLifecycleState.resumed) {
      hideContentOverlay!.remove();
      hideContentOverlay = null;
    }
    if (state == AppLifecycleState.hidden &&
        !AuthPage.isActive &&
        !IO.isSelectingFiles) {
      AuthPage.isActive = true;
      App.rootContext.to(
        () => AuthPage(
          onSuccessfulAuth: () {
            App.rootContext.pop();
            AuthPage.isActive = false;
          },
        ),
      );
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void didChangePlatformBrightness() {
    syncReaderNightModeWithSystem();
    super.didChangePlatformBrightness();
  }

  /// When "follow system" is enabled, keep the reader night mode in sync with
  /// the system dark/light setting: on in dark mode, off in light mode.
  ///
  /// [rebuild] must be false when called during `initState` (the first build
  /// hasn't happened yet, and forcing one then is illegal).
  void syncReaderNightModeWithSystem({bool rebuild = true}) {
    if (appdata.settings['readerNightModeFollowSystem'] != true) {
      return;
    }
    final isDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    if ((appdata.settings['readerNightMode'] == true) == isDark) {
      return;
    }
    appdata.settings['readerNightMode'] = isDark;
    appdata.saveData(deferredInitCompleter.isCompleted);
    if (rebuild) {
      App.forceRebuild();
    }
  }

  void forceRebuild() {
    syncOhosStartupTheme();
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
  }

  Color translateColorSetting() {
    return switch (appdata.settings['color']) {
      'red' => Colors.red,
      'pink' => Colors.pink,
      'purple' => Colors.purple,
      'green' => Colors.green,
      'orange' => Colors.orange,
      'blue' => Colors.blue,
      'yellow' => Colors.yellow,
      'cyan' => Colors.cyan,
      _ => Colors.blue,
    };
  }

  ThemeData getTheme(
    Color primary,
    Color? secondary,
    Color? tertiary,
    Brightness brightness,
  ) {
    String? font;
    List<String>? fallback;
    if (App.isLinux || App.isWindows) {
      font = 'Noto Sans CJK';
      fallback = [
        'Segoe UI',
        'Noto Sans SC',
        'Noto Sans TC',
        'Noto Sans',
        'Microsoft YaHei',
        'PingFang SC',
        'Arial',
        'sans-serif'
      ];
    }
    final colors = SeedColorScheme.fromSeeds(
      primaryKey: primary,
      secondaryKey: secondary,
      tertiaryKey: tertiary,
      brightness: brightness,
      tones: FlexTones.vividBackground(brightness),
    );
    return ThemeData(
      colorScheme: colors,
      sliderTheme: appSliderTheme(colors),
      fontFamily: font,
      fontFamilyFallback: fallback,
      // ExpansionTile shows top/bottom divider lines when expanded by default.
      // Override globally with borderless shapes so no expandable tile (task
      // cards, reader settings groups, source dialogs, etc.) renders stray
      // lines at its top and bottom.
      expansionTileTheme: const ExpansionTileThemeData(
        shape: Border(),
        collapsedShape: Border(),
      ),
      // Covers the routes that aren't AppPageRoute (they read the same setting
      // themselves) so the back gesture behaves the same everywhere (#194).
      pageTransitionsTheme:
          App.isAndroid && appdata.settings['enablePredictiveBack'] == false
          ? const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
              },
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(builder: (light, dark) {
      Color? primary, secondary, tertiary;
      if (appdata.settings['color'] != 'system' ||
          light == null ||
          dark == null) {
        primary = translateColorSetting();
      } else {
        primary = light.primary;
        secondary = light.secondary;
        tertiary = light.tertiary;
      }
      return MaterialApp(
        title: "VeneraX",
        home: const StartupPage(),
        debugShowCheckedModeBanner: false,
        theme: getTheme(primary, secondary, tertiary, Brightness.light),
        navigatorKey: App.rootNavigatorKey,
        navigatorObservers: [App.rootRouteObserver],
        darkTheme: getTheme(primary, secondary, tertiary, Brightness.dark),
        themeMode: switch (appdata.settings['theme_mode']) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system
        },
        color: Colors.transparent,
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        locale: () {
          var lang = appdata.settings['language'];
          if (lang == 'system') {
            return null;
          }
          return switch (lang) {
            'zh-CN' => const Locale('zh', 'CN'),
            'zh-TW' => const Locale('zh', 'TW'),
            'en-US' => const Locale('en'),
            _ => null
          };
        }(),
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('zh', 'TW'),
          Locale('en'),
        ],
        builder: (context, widget) {
          ErrorWidget.builder = (details) {
            Log.error("Unhandled Exception",
                "${details.exception}\n${details.stack}");
            return Material(
              child: Center(
                child: Text(details.exception.toString()),
              ),
            );
          };
          if (widget != null) {
            /// 如果无法检测到状态栏高度设定指定高度
            /// https://github.com/flutter/flutter/issues/161086
            var viewPaddingTop = MediaQuery.viewPaddingOf(context).top;
            var isPaddingCheckError =
                viewPaddingTop <= 0 || viewPaddingTop > 200;

            if (isPaddingCheckError && Platform.isAndroid) {
              widget = MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    viewPadding: const EdgeInsets.only(
                      top: 15,
                      bottom: 15,
                    ),
                    padding: const EdgeInsets.only(
                      top: 15,
                      bottom: 15,
                    ),
                  ),
                  child: widget);
            }

            widget = OverlayWidget(widget);
            if (App.isDesktop) {
              widget = Shortcuts(
                shortcuts: {
                  LogicalKeySet(LogicalKeyboardKey.escape): VoidCallbackIntent(
                    App.pop,
                  ),
                },
                child: MouseBackDetector(
                  onTapDown: App.pop,
                  child: WindowFrame(widget),
                ),
              );
            }
            return _SystemUiProvider(Material(
              color: App.isLinux ? Colors.transparent : null,
              child: widget,
            ));
          }
          throw ('widget is null');
        },
      );
    });
  }
}

class _SystemUiProvider extends StatelessWidget {
  const _SystemUiProvider(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var brightness = Theme.of(context).brightness;
    SystemUiOverlayStyle systemUiStyle;
    if (brightness == Brightness.light) {
      systemUiStyle = SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      );
    } else {
      systemUiStyle = SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: child,
    );
  }
}
