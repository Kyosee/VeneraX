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

Local WebDAV property reads use Depth 0, avoiding a directory listing when only
metadata is needed. Copy and move forward cancellation to the network request.
The list package removes obsolete null assertions and unused private methods;
this is analyzer compatibility work, not a scrolling performance claim.

## Updating

1. Review upstream changes against the revision listed above and retain local
   fixes and tests. Update the provenance row when importing a newer revision.
2. Run `flutter pub get` in the standard checkout. Review `pubspec.lock`; an
   import must not silently upgrade unrelated packages.
3. Run affected application and package tests, then static analysis. Validate
   the Flutter OH preparation in its separate checkout when dependencies change.
4. Commit source and lockfile changes together. Never edit Pub's shared cache.

## Owned forks kept external

Every Git dependency in the application manifest resolves from Kyosee's forks.
Native/federated source remains in separate repositories to retain platform
build trees and history. Forking changes maintenance ownership; it does not by
itself improve performance. Exact revisions remain in `pubspec.yaml` and
`pubspec.lock`, including all federated WebView subpackages.

| Dependencies | Maintenance decision |
| --- | --- |
| [`flutter_qjs`](https://github.com/Kyosee/flutter_qjs) | Forked at the existing revision. Preserve the isolated OH loader adaptation and native build inputs. No new runtime change. |
| [`flutter_7zip`](https://github.com/Kyosee/flutter_7zip) | Close discovery/worker handles after extraction and on failure; release path memory on file errors, reject invalid worker counts, and avoid empty workers. Include an OH loader. Native extraction regressions run in the fork. |
| [`lodepng_flutter`](https://github.com/Kyosee/lodepng_flutter) | Fix freed-memory views, decoded dimensions, native error handling and invalid RGBA input; include an OH loader. Preserve the reader's pointer/finalizer path. Native codec regressions run in the fork. |
| [`flutter_inappwebview`](https://github.com/Kyosee/flutter_inappwebview) | Forked with all six federated platform/interface packages at the same revision. Preserve the separate official OH implementation and existing compatibility patches. |
| [`desktop_webview_window`](https://github.com/Kyosee/flutter_desktop_webview) | Forked at the existing revision, retaining WebView2 loader binaries and WIL headers. No new runtime change. |
| [`flutter_saf`](https://github.com/Kyosee/flutter_saf) | GitHub fork at the existing revision, preserving its original notices. The placeholder LICENSE is not an established license grant; this fork does not resolve that upstream ambiguity or relicense the code. No vendoring or behavior change. |
| [`flutter_to_debian`](https://github.com/Kyosee/flutter_to_debian) | Forked at the existing revision. Linux packaging now runs the locked project dependency, propagates failures and restores templates on failure. |
| [`flutter_onnxruntime`](https://github.com/Kyosee/flutter_onnxruntime) | Existing owned fork and pinned revision. No new change in this migration. |
