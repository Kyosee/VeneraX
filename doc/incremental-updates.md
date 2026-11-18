# Incremental updates

Android and Windows can download an optional delta from GitHub Releases. Complete
installers remain available for new installs, old clients and recovery. No extra
service or Flutter engine modification is required.

## Release artifacts

- Keep all existing full packages and names.
- `update-manifest.json` identifies optional patches for this release. It is
  uploaded only when at least one patch was produced.
- `VeneraX-OLD-to-NEW-android-ABI.patch` is a standard BSDIFF40 patch of the final,
  signed APK. Applying it reproduces the complete published APK byte for byte.
- `VeneraX-OLD-to-NEW-windows-x64.patch` is a ZIP containing `delta.json` and
  changed file payloads. Unchanged files are copied from the installed directory;
  changed files are either BSDIFF40 or complete files. The client verifies every
  result, creates a temporary complete ZIP and uses the existing Windows updater.

The release workflow considers the two most recent releases in the same channel
and publishes a patch only if it saves at least 20% compared with the matching
complete package. Clients need one full upgrade to obtain delta support. Missing,
unsupported or invalid manifests select the normal full update. Prereleases are
not offered by the existing stable update checker.

Patches are optional, so generating them can never block a release: a failure,
an unavailable release history or the 30 minute step timeout leaves a release
with full packages only and a warning in the run log. A rerun of the Release job
first removes delta assets an earlier attempt uploaded to the same draft.

## Choosing full or incremental delivery

By default, release generation automatically supplies worthwhile patches.
To override this for a release, commit `release-notes/vVERSION.update.json`
in the release commit, before the tag is pushed (the Release job reads the
tagged commit), for example:

```json
{"android": "auto", "windows": "full"}
```

`auto` publishes patches only when compatible and at least 20% smaller; `full`
publishes no patches for that platform. Omitted platforms default to `auto`.
Set both to `full` to require full-package downloads for this version, for
example after a signing change or when an older client must not apply a patch.
The complete installers are always published. There is deliberately no mode that
forces an incompatible patch on an old client or removes the recovery package.
The `analyze` workflow rejects a misnamed file or an invalid key or value on
`master`; if one still reaches a release, that release ships full packages only.

To stop deltas after a release was published, delete its `update-manifest.json`
asset. Clients then download the full package.

## Integrity and recovery

The client uses GitHub's existing SHA-256 release asset digests to verify the
manifest and patch. The manifest names assets in that same release; it does not
supply arbitrary download URLs. Old-input digests are necessary because the same
version and ABI can be rebuilt or modified. The version alone cannot identify
the bytes needed by a binary patch. APK output is verified against the complete
release asset and then installed by Android, retaining normal signature checks.

All reconstruction and package hashing happen off the UI isolate, in a unique
cache attempt. Cancellation is checked at most every 100 ms and waits for writers
to close before removing that attempt. Errors, including insufficient disk space,
leave the installed app untouched. A failed delta requires another user click
before downloading the full package. A later update removes day-old attempts that
were handed to an installer.

Windows prepares the complete directory on the installation volume, switches
directories and restores the original if activation fails. Any open handle inside
a directory blocks moving it, so copies and moves are retried for about five
seconds to wait out antivirus scanners and indexers; a file that stays locked
leaves the installation intact and the update fails. The updater deletes its
temporary package and extracted files afterwards. Incremental installation
requires the bundled executable updater and never falls back to the legacy
in-place PowerShell copier. It does not treat an application startup crash as an
automatic rollback signal.

Android store split installations use full updates. An APK of a different ABI
or a modified APK cannot serve as a patch input. Choosing a matching per-ABI full
package also avoids downloading the universal package unnecessarily.

HarmonyOS, iOS, macOS and Linux retain their existing update paths. In particular,
an unsigned HarmonyOS release HAP differs from a locally re-signed installed HAP.

## Development checks

Use Flutter 3.44.3. Run the update tests listed in `.github/workflows/analyze.yml`.
The release-only Python generator uses `bsdiff4==1.2.6`; the app uses the existing
`archive` and `crypto` packages and adds no native patching dependency. Python
tests exercise the generator independently from Dart decoding fixtures. Real
release-pair measurements are evidence for those pairs only, not guaranteed
savings for future versions.

## Verification evidence

The implementation was checked with the final published v2.3.12 and v3.0.0
assets, using Python generation and Dart reconstruction independently:

| Package | Patch bytes | Complete bytes | Preparation (desktop, AOT) | Result |
| --- | ---: | ---: | ---: | --- |
| Android arm64-v8a | 8,812,071 | 37,107,677 | 1.8 s | Reconstructed APK matches the published SHA-256 |
| Windows x64 | 3,757,358 | 38,122,213 | 6 s | Every file matches; the compiled updater installs it |

Windows preparation took 54 to 59 s before cancellation checks were throttled;
one file probe per BSDIFF40 control tuple (240,000 for this pair) cost 45 s.
Phones are slower than the desktop figures above.

Automated coverage includes wrong versions/ABIs/digests, damaged and oversized
data, traversal and ZIP links, bounded decompression, cancellation races and
throttling, filesystem failures and retry, Windows locked files (brief and
persistent) and failed restoration, release policy/history failures, rerun
cleanup and fail-safe generation, and simplified/traditional Chinese and English
dialogs at large text sizes. These checks do not simulate physical power loss
during Windows directory activation, nor replace ARM64 Android phone testing.
