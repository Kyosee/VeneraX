# Release Notes (multi-language)

Each release ships **two** changelog files in this directory, one per language:

- `v<X.Y.Z>.en.md` — English (fallback for any non-Chinese locale)
- `v<X.Y.Z>.zh-CN.md` — Simplified Chinese

The file name version **must** match the git tag exactly (e.g. tag `v2.0.7`
→ `v2.0.7.en.md`). The app reads these at the tag-pinned raw URL:

```
https://raw.githubusercontent.com/Kyosee/venera/<tag>/release-notes/<tag>.<lang>.md
```

## How the in-app update dialog uses them

`lib/pages/settings/about.dart` (`_fetchChangelogLines`) picks the language by
`App.locale`: Chinese → `zh-CN`, everything else → `en`. If the localized file
is missing it falls back to `en`; if neither exists the dialog simply omits the
changelog section.

The dialog renders **one entry per line** as a bullet list. Parsing rules
(`_parseChangelogLines`):

- Markdown headings (`#`, `##`, `###`) are dropped.
- Lines wrapped in `**...**` (e.g. the Full Changelog footer) are dropped.
- Leading list markers (`-`, `*`, `+`) are stripped.
- Blank lines are ignored.

So keep every user-facing entry on its own line as a `- ` bullet under a
section heading.

## CHANGELOG.md

`CHANGELOG.md` (Chinese) and `CHANGELOG_EN.md` (English) at the repo root are
generated from these files by `.github/scripts/gen-changelog.mjs`, in the
`Update_Changelog` job after each stable release. Only published stable
releases are listed. Edit the files here, never the generated ones; the next
stable release rewrites both.

## GitHub prerelease titles

Use `v<version> <stage> <number> (<platforms>)`, for example
`v3.0.2 Beta 2 (Android & HarmonyOS)` or
`v2.3.12 Test 1 (HarmonyOS)`. Write Alpha, Beta, RC or Test as
indicated by the version. Omit the number if the prerelease has none.
List platforms with an installable package in the order Android, HarmonyOS,
iOS, Windows, macOS, Linux. Both release workflows use the same formatter.
For manual previews, pass the version and the package paths to the formatter.

```sh
node .github/scripts/prerelease-title.mjs 3.0.2-beta.2 release-assets/*
```

## GitHub Release body

The release body should link to both language files so users on the web can
switch language. See the `venera-release` skill for the exact body template and
publishing flow.
