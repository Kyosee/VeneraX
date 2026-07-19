part of 'settings_page.dart';

/// Lets the user switch the OS-level launcher icon between built-in presets.
/// Mobile only — desktop taskbar/Dock icons are fixed at build time, so the
/// entry that opens this page is hidden on desktop.
class LauncherIconSettings extends StatefulWidget {
  const LauncherIconSettings({super.key});

  @override
  State<LauncherIconSettings> createState() => _LauncherIconSettingsState();
}

class _LauncherIconSettingsState extends State<LauncherIconSettings> {
  late LauncherIconPreset selected = LauncherIconService.current;
  bool applying = false;

  static const _previews = {
    LauncherIconPreset.defaultIcon: 'assets/new_logo.png',
    LauncherIconPreset.orig: 'assets/venera_original.png',
    LauncherIconPreset.flat: 'assets/user_logo.png',
    LauncherIconPreset.mono: 'assets/new_logo2.png',
    LauncherIconPreset.illust: 'assets/new_logo3.png',
  };

  String _label(LauncherIconPreset preset) => switch (preset) {
    LauncherIconPreset.defaultIcon => "Default".tl,
    LauncherIconPreset.orig => "Classic".tl,
    LauncherIconPreset.flat => "Flat".tl,
    LauncherIconPreset.mono => "Monogram".tl,
    LauncherIconPreset.illust => "Illustrated".tl,
  };

  Future<void> _select(LauncherIconPreset preset) async {
    if (applying || preset == selected) return;
    setState(() => applying = true);
    var ok = await LauncherIconService.apply(preset);
    if (!mounted) return;
    setState(() {
      applying = false;
      if (ok) selected = preset;
    });
    if (!ok) {
      context.showMessage(message: "This device does not support this".tl);
      return;
    }
    // The in-app logo (sidebar / About) follows the chosen preset, so repaint
    // the whole tree once the switch succeeds.
    App.forceRebuild();
    // Android now switches the launcher alias immediately (see
    // LauncherIconService.apply); the home-screen icon may still take a moment
    // for the launcher to repaint. iOS pops its own system alert. Windows swaps
    // only the live window/taskbar/tray icon.
    context.showMessage(
      message: App.isIOS
          ? "Icon changed".tl
          : "Icon updated".tl,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("App Icon".tl)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              LauncherIconService.isWindowIconOnly
                  ? "Changes the window and taskbar icon while the app is running. The pinned and Start menu icon stays the same."
                      .tl
                  : "Change the icon shown on your home screen.".tl,
              style: ts.s12.copyWith(color: context.colorScheme.outline),
            ),
          ),
          ...LauncherIconPreset.values.map(_buildTile),
        ],
      ),
    );
  }

  Widget _buildTile(LauncherIconPreset preset) {
    var isSelected = preset == selected;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        border: Border.all(
          color: isSelected
              ? context.colorScheme.primary
              : context.colorScheme.outlineVariant,
          width: isSelected ? 1.6 : 0.6,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: applying ? null : () => _select(preset),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  _previews[preset]!,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(_label(preset), style: ts.s16)),
              if (isSelected)
                Icon(Icons.check_circle, color: context.colorScheme.primary)
              else
                Icon(
                  Icons.circle_outlined,
                  color: context.colorScheme.outlineVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
