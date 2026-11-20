## What's Changed

### Added
- No standalone features were added in this release.

### Changed
- This 3.0.2 Beta 1 preview is available for HarmonyOS only, for early verification of fixes and feedback.

### Fixed
- Fixed quick horizontal swipes not reliably collecting or uncollecting the current image in webtoon mode when swipe collection is enabled (#349).
- Fixed a crash that could occur when a network request was cancelled (#349).

### Removed
- No features were removed in this release.

**HarmonyOS installation**: For phones and tablets, choose the ARM64 package ending in `harmonyos-unsigned.hap`; `harmonyos-emulator-x64-unsigned.hap` is for x64 emulators only. Both HAPs are unsigned and require your own signature for a physical device. HarmonyOS displays the native version as `3.0.2.1`, which corresponds to this `3.0.2-beta.1` preview.

**Verification and feedback**: The request cancellation callback crash was reproduced with the previous network library, and the updated library passed the same regression test. Returning to reading after backgrounding or locking the screen still needs verification on HarmonyOS devices. If another crash occurs, reopen the app, export diagnostic information, and include the time it happened.

**Full Changelog**: https://github.com/Kyosee/VeneraX/compare/v3.0.1...harmonyos-3.0.2-beta.1
