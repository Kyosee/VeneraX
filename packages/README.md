# Locally maintained dependencies

These packages are part of VeneraX's source tree. Keep their public package
names, upstream notices and licenses. App-specific fixes and regression tests
can be reviewed with the application that uses them.

| Package | Upstream revision | License | Reason |
| --- | --- | --- | --- |
| `photo_view` | [venera-app/photo_view](https://github.com/venera-app/photo_view), `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c` | MIT | Reader image layout, zoom and lifecycle fixes |
| `scrollable_positioned_list` | [venera-app/flutter.widgets](https://github.com/venera-app/flutter.widgets), `09e756b1f1b04e6298318d99ec20a787fb360f59`, `packages/scrollable_positioned_list` | BSD-3-Clause | Continuous reader positioning and chapter navigation |
| `webdav_client` | [venera-app/webdav_client](https://github.com/venera-app/webdav_client), `2f669c98fb81cff1c64fee93466a1475c77e4273` | BSD-3-Clause | Backup and comic-library protocol compatibility |

Only package source, manifests, notices and relevant tests are included; upstream
demo applications and generated build output are omitted. These three packages
are Dart-only and use the same source on standard Flutter and Flutter OH.

The list package's legacy widget tests target upstream APIs removed by the
existing fork (including scroll offset controllers), so only its compatible
positioned-list tests are included. VeneraX's continuous-reader tests cover the
fork's public widget integration. PhotoView tests use the app's Flutter test SDK.

Local PhotoView fixes retain resolved images when their stream is unchanged,
release image handles on replacement/disposal, and calculate the zoom reset
scale from the current viewport after rotation.

## Updating

1. Review upstream changes against the revision listed above and retain local
   fixes and tests. Update the provenance row when importing a newer revision.
2. Run `flutter pub get` in the standard checkout. Review `pubspec.lock`; an
   import must not silently upgrade unrelated packages.
3. Run affected application and package tests, then static analysis. Validate
   the Flutter OH preparation in its separate checkout when dependencies change.
4. Commit source and lockfile changes together. Never edit Pub's shared cache.

## Dependencies kept external

| Dependencies | Maintenance decision |
| --- | --- |
| `flutter_qjs`, `flutter_7zip`, `lodepng_flutter` | Keep pinned native source dependencies and existing isolated OH loader adaptations; importing their native trees would add unrelated build ownership. |
| `flutter_inappwebview` | Keep its pinned federated packages together; preserve the separate official OH implementation and local compatibility patches. |
| `desktop_webview_window` | Keep pinned: its Windows build includes WebView2 loader binaries and WIL headers, and no application-specific change currently needs a source import. |
| `flutter_saf` | Keep pinned: the selected revision's LICENSE contains a placeholder rather than a license grant. Resolve licensing before copying or redistributing a local fork. |
| `flutter_to_debian` | Pin its already resolved revision; it is a packaging tool with no runtime customization needed. |
| `flutter_onnxruntime` | Keep the existing owned fork and pinned revision. |
