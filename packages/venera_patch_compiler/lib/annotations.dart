/// Annotations a patch source file uses.
///
/// This library is imported by patch sources, never by the app. It exists as a
/// separate entry point from `venera_patch_compiler.dart` so a patch file pulls
/// in the annotation and nothing else — not the analyzer, not the compiler.
///
/// A patch is ordinary Dart:
///
/// ```dart
/// import 'package:venera_patch_compiler/annotations.dart';
///
/// @PatchOverride('backupDateFromLeadingSegment')
/// int fixedDate(int value) {
///   // ...
/// }
/// ```
///
/// The seam name is resolved against the target build's surface manifest at
/// compile time, so a typo or a seam that build does not have is a build failure
/// naming the file and line — not a patch that installs and quietly does
/// nothing.
library;

/// Marks a top-level function as the replacement for a named seam.
class PatchOverride {
  const PatchOverride(this.seam);

  /// The seam's name, as recorded in the surface manifest.
  final String seam;
}
