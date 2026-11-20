## What's changed

### Added
- No standalone features were added in this release.

### Changed
- This 3.0.2 Beta 2 preview includes Android and HarmonyOS packages for testing fixes and sharing feedback.

### Fixed
- Fixed quick horizontal swipes not reliably collecting or uncollecting the current image in continuous reading mode when swipe collection is enabled (#349).
- Fixed a possible crash when a network request is cancelled (#349).
- Fixed a possible Android crash when accessing an authorized folder after a background task ends (#349).

### Removed
- No features were removed in this release.

**Android installation**: If you are unsure of your device architecture, choose the universal APK without an architecture suffix. It can be installed over the existing stable release.

**HarmonyOS installation**: Choose the ARM64 package containing `harmonyos-unsigned.hap` for phones and tablets. The `harmonyos-emulator-x64-unsigned.hap` package is only for x64 emulators. Both HAP packages are unsigned; physical devices require signing. HarmonyOS displays version `3.0.2.2`, which corresponds to this `3.0.2-beta.2` preview.

**Feedback**: Reading, backgrounding, screen locking and resuming still need testing on physical Android and HarmonyOS devices. If another crash occurs, reopen the app, export diagnostics and include the time of the crash.

**Full changelog**: https://github.com/Kyosee/VeneraX/compare/v3.0.1...mobile-3.0.2-beta.2
