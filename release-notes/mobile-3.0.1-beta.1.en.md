## What's Changed

### Added
- Importing a backup created with Export app data now restores WebDAV, follow-update folders, image translation concurrency, and other device settings that have not yet been configured on this device; WebDAV sync backups do not include these device settings (#349).

### Changed
- This Beta preview is available for Android and HarmonyOS only, for early access to fixes and feedback.
- Local comics on the home page now follow the sort order selected in the local library (#351).
- Reading statistics remembers the last selected tab (#350).
- Smoother rapid page turns when reading local comics with two-page layouts or split spreads (#352).
- Reduced interface stalls while exporting backups, preparing sync data, and refreshing home screen widgets (#352, #355).

### Fixed
- Fixed interface stalls, black screens, or freezes while checking local comic folders when opening the app or entering from a home screen widget or app shortcut (#349).
- Fixed follow-update widgets and app shortcuts opening a separate list instead of the regular Follow Updates page (#349).
- Fixed repeated navigation from widgets, app shortcuts, or notifications stacking duplicate pages and requiring multiple back presses (#349).
- Restored the HarmonyOS startup icon's size and rounded corners (#349).
- Fixed per-comic reading settings saved for a local comic on another device not taking effect; settings already enabled on this device still take priority (#353).
- Fixed cards and buttons shifting when switching draw modes (#354).

### Removed
- No features were removed in this release.

**HarmonyOS installation**: For phones and tablets, choose the ARM64 package ending in `harmonyos-unsigned.hap`; `harmonyos-emulator-x64-unsigned.hap` is for x64 emulators only. Both HAPs are unsigned and require your own signature for a physical device; ARM64 device installation and runtime validation are not claimed for this preview. HarmonyOS displays the native version as `3.0.1.1`, which corresponds to this `3.0.1-beta.1` preview.

**Full Changelog**: https://github.com/Kyosee/VeneraX/compare/v3.0.0...mobile-3.0.1-beta.1
