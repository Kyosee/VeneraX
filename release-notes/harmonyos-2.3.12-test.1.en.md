## What's Changed

### Added
- First VeneraX ARM64 HarmonyOS preview, including the complete app's sources, reading, downloads, history/favorites, backups and sync.
- Export CBZ, PDF, EPUB and comic archives through HarmonyOS system save dialogs.

### Changed
- The app version remains 2.3.12+257; this HarmonyOS-only preview does not replace stable releases for other platforms.
- The test HAP is unsigned. Phone installation requires your own certificate and a debug profile for the target device; see the installation guide.
- Core workflows have been exercised on the official emulator; signed phone installation, PDF rendering, PIN/biometric authentication, folder authorization, real QR scanning, site-specific login and online translation still need device testing.

### Fixed
- Fix page navigation and saved progress getting out of sync in continuous right-to-left reading.
- Fix chapter page counts, covers and repeated chapters across comic archive round trips, while preserving all pages in older CBZ files.
- Fix exports showing completion after cancellation during saving, and some failed tasks not finishing correctly.
- Fix comic archive import and export paths for Android external folders.
- Fix HarmonyOS background notifications opening the wrong page after switching between downloads and sync.
- Fix HarmonyOS embedded web navigation potentially sending the full source page URL unnecessarily.

**Installation guide**: https://github.com/Kyosee/VeneraX/blob/harmonyos-2.3.12-test.1/doc/harmonyos-testing.md

**Full Changelog**: https://github.com/Kyosee/VeneraX/compare/v2.3.12...harmonyos-2.3.12-test.1
