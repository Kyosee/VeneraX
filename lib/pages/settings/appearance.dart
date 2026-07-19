part of 'settings_page.dart';

class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({super.key});

  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Appearance".tl)),
        SelectSetting(
          title: "Theme Mode".tl,
          settingKey: "theme_mode",
          optionTranslation: {
            "system": "System".tl,
            "light": "Light".tl,
            "dark": "Dark".tl,
          },
          onChanged: () async {
            App.forceRebuild();
          },
        ).toSliver(),
        SelectSetting(
          title: "Theme Color".tl,
          settingKey: "color",
          optionTranslation: {
            "system": "System".tl,
            "red": "Red".tl,
            "pink": "Pink".tl,
            "purple": "Purple".tl,
            "green": "Green".tl,
            "orange": "Orange".tl,
            "blue": "Blue".tl,
          },
          onChanged: () async {
            await App.init();
            App.forceRebuild();
          },
        ).toSliver(),
        ListTile(
          title: Text("Home Page Layout".tl),
          subtitle: Text("Reorder or hide home sections".tl),
          leading: const Icon(Icons.dashboard_customize_outlined),
          trailing: const Icon(Icons.arrow_right),
          onTap: () {
            context.to(() => const HomeLayoutSettings());
          },
        ).toSliver(),
        ListTile(
          title: Text("Image Favorites Tabs".tl),
          subtitle: Text("Reorder or hide the Tags / Authors / Comics tabs".tl),
          leading: const Icon(Icons.tab_outlined),
          trailing: const Icon(Icons.arrow_right),
          onTap: () {
            context.to(() => const ImageFavoritesTabsSettings());
          },
        ).toSliver(),
        // Icon switching exists on mobile and Windows; other desktops have a
        // fixed build-time icon (see LauncherIconService.isSupported).
        if (LauncherIconService.isSupported)
          ListTile(
            title: Text("App Icon".tl),
            subtitle: Text(
              LauncherIconService.isWindowIconOnly
                  ? "Choose the window and taskbar icon".tl
                  : "Choose the home screen icon".tl,
            ),
            leading: const Icon(Icons.apps_outlined),
            trailing: const Icon(Icons.arrow_right),
            onTap: () {
              context.to(() => const LauncherIconSettings());
            },
          ).toSliver(),
      ],
    );
  }
}
