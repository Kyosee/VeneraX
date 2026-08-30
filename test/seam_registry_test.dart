// The seam registry must describe reality.
//
// `SeamIds.installed` is what the surface manifest publishes, and it is the
// promise a patch author compiles against: "this build can hand these functions
// to a patch". Nothing in the type system keeps that promise honest — it is a
// hand-maintained map, and the code it describes lives in a different package.
//
// Drift in the dangerous direction is silent and severe. An id published in
// `installed` with no live `patched()` call site lets a patch compile, sign,
// install, and report success while overriding nothing at all: the registry
// holds an entry no code ever looks up. That is precisely the failure this whole
// mechanism exists to avoid — a fix that appears applied and isn't — and it
// would be discovered only by someone noticing the bug is still there.
//
// So this test reads `lib/` and cross-checks both directions.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_patch/venera_patch.dart';

/// Matches `patched(` / `patchedAsync(` followed by the seam id it targets.
///
/// Deliberately shallow: it reads `SeamIds.<name>` as written in the source
/// rather than resolving anything. A seam whose id is computed instead of named
/// would not be found — which is why the assertion below also requires that
/// every installed id IS found, so an unmatchable call site fails the test
/// rather than slipping past it.
final _seamCall = RegExp(
  r'patched(?:Async)?(?:<[^>]*>)?\(\s*SeamIds\.(\w+)',
  multiLine: true,
);

/// Seam names with a live call site in `lib/`, mapped to where they were found.
Map<String, List<String>> _callSitesInLib() {
  final found = <String, List<String>>{};
  for (final entry in Directory('lib').listSync(recursive: true)) {
    if (entry is! File || !entry.path.endsWith('.dart')) continue;
    final path = entry.path.replaceAll('\\', '/');
    final source = entry.readAsStringSync();
    for (final match in _seamCall.allMatches(source)) {
      final name = match.group(1)!;
      // Line number, so a failure points at the call rather than the file.
      final line = source.substring(0, match.start).split('\n').length;
      (found[name] ??= []).add('$path:$line');
    }
  }
  return found;
}

void main() {
  test('every published seam has a live call site', () {
    final callSites = _callSitesInLib();
    final orphaned = <String>[];

    SeamIds.installed.forEach((name, id) {
      if (!callSites.containsKey(name)) {
        orphaned.add('  $name (0x${id.toRadixString(16)})');
      }
    });

    expect(
      orphaned,
      isEmpty,
      reason:
          'These seams are published in SeamIds.installed but no patched() '
          'call site names them in lib/.\n'
          'A patch targeting one would install cleanly, report success, and '
          'override nothing — the exact "fix that looks applied and isn\'t" '
          'failure this mechanism exists to prevent.\n'
          'Either add the seam at its call site, or remove it from '
          'installed (leaving the id declared and RESERVED):\n'
          '${orphaned.join('\n')}',
    );
  });

  test('every call site is published', () {
    // The harmless direction, but still worth catching: a seam nobody can name
    // is dead weight paying the gate cost on every call for nothing. Usually it
    // means someone added the call site and forgot the map entry, so the fix is
    // one line and the patch they wanted becomes possible.
    final callSites = _callSitesInLib();
    final unpublished = <String>[];

    callSites.forEach((name, sites) {
      if (!SeamIds.installed.containsKey(name)) {
        unpublished.add('  $name at ${sites.join(", ")}');
      }
    });

    expect(
      unpublished,
      isEmpty,
      reason: 'These seams have a call site but are not in '
          'SeamIds.installed, so no patch can target them:\n'
          '${unpublished.join('\n')}',
    );
  });

  test('a reserved id is never published', () {
    // Reserved ids are ones that once meant a particular function. Publishing
    // one again after its meaning moved would let a patch built against the old
    // meaning install and override the wrong code — so reuse is barred, and the
    // constants stay declared purely to keep the number taken.
    final publishedIds = SeamIds.installed.values.toSet();
    expect(
      publishedIds.contains(SeamIds.backupInfoFromFileName),
      isFalse,
      reason: 'backupInfoFromFileName is RESERVED, and for a second reason '
          'beyond having no call site: it returns a RemoteBackupInfo, and the '
          'host surface binds no constructor for that type. A patch overriding '
          'it could not build its own return value, so publishing the seam '
          'would advertise something unusable.',
    );
  });

  test('no two published seams share an id', () {
    // Two names for one id would make the surface manifest ambiguous: a patch
    // naming either would land on the same override slot, and whichever seam ran
    // second would silently take the other's patch.
    final byId = <int, String>{};
    final clashes = <String>[];
    SeamIds.installed.forEach((name, id) {
      final prior = byId[id];
      if (prior != null) {
        clashes.add('0x${id.toRadixString(16)}: $prior and $name');
      }
      byId[id] = name;
    });
    expect(clashes, isEmpty, reason: clashes.join('\n'));
  });

  test('the installed seams are the ones we expect', () {
    // Pins the current state so growth is deliberate. When a seam is added this
    // test fails, which is the prompt to check the new seam actually belongs on
    // a re-runnable function — the safety rule the fallback in patched() rests
    // on, and the one thing no automated check can verify.
    //
    // Every entry below was checked against that rule by hand:
    //
    // * `backupDateFromLeadingSegment` — int in, DateTime out, arithmetic only.
    // * `compareAppVersions` — two strings in, bool out, parses and compares.
    // * `nextSyncVersion` — two ints in, int out, a max and an increment.
    // * `shouldSkipStaleUpload` — bool + two ints in, bool out, one comparison.
    // * `mergeIncomingDataVersion` — two ints in, int out, a range check.
    // * `isOwnPendingPublish` — names and sizes in, bool out, equality only.
    //
    // None writes a file, touches the database, or fires a request, so the
    // fallback re-running the original after a mid-call fault costs nothing but
    // time. Every one of them also lives in `sync_protocol.dart`'s "pure
    // decision logic" layer or is a comparable predicate — which is exactly the
    // shape the mechanism is for, and where this app's worst bugs (#80, #86,
    // #133, #51) actually were.
    expect(
      SeamIds.installed.keys.toList(),
      [
        'backupDateFromLeadingSegment',
        'compareAppVersions',
        'nextSyncVersion',
        'shouldSkipStaleUpload',
        'mergeIncomingDataVersion',
        'isOwnPendingPublish',
      ],
      reason: 'Seam set changed. Confirm the new seam sits on a function where '
          're-running the original after a mid-call fault is harmless (pure '
          'computation, no side effects), then update this list.',
    );
  });
}
