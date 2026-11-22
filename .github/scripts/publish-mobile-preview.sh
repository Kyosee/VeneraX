#!/usr/bin/env bash
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

cd "$GITHUB_WORKSPACE"
[[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]] || fail "The checkout differs from the build commit."
app_version=$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml)
[[ "$app_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+)\+[0-9]+$ ]] || fail "Expected a prerelease version in pubspec.yaml."
version=${BASH_REMATCH[1]}
tag="mobile-$version"
notes="release-notes/$tag"
[[ -s "$notes.en.md" && -s "$notes.zh-CN.md" ]] || fail "Missing release notes for $tag."

root="$RUNNER_TEMP/mobile-preview"
assets=("$root/android/VeneraX-$version.apk")
for abi in arm64-v8a armeabi-v7a x86_64; do
  assets+=("$root/android/VeneraX-$version-$abi.apk")
done
assets+=("$root/harmonyos/VeneraX-$app_version-harmonyos-unsigned.hap")
scope=${PREVIEW_SCOPE:-mobile}
case "$scope" in
  mobile) ;;
  mobile-windows)
    assets+=("$root/windows/VeneraX-$version-windows-installer.exe" "$root/windows/VeneraX-$version-windows.zip")
    ;;
  *) fail "Unknown preview scope: $scope" ;;
esac
for asset in "${assets[@]}"; do
  [[ -f "$asset" && -s "$asset" ]] || fail "Missing or empty package: ${asset##*/}"
done
count=$(find "$root" -type f \( -iname '*.apk' -o -iname '*.hap' -o -iname '*.exe' -o -iname '*.zip' \) -printf x | wc -c)
(( count == ${#assets[@]} )) || fail "Unexpected additional packages in the downloaded artifacts."

repo_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
title=$(node .github/scripts/prerelease-title.mjs "$version" "${assets[@]}")
body_file="$root/release-body.md"
{
  node .github/scripts/release-downloads.mjs "$repo_url" "$tag" "$app_version" "$scope"
  printf '\n> **Language / 语言**: [English](%s/blob/%s/%s.en.md) · [简体中文](%s/blob/%s/%s.zh-CN.md)\n\n' \
    "$repo_url" "$tag" "$notes" "$repo_url" "$tag" "$notes"
  cat "$notes.en.md"
} > "$body_file"

api="repos/$GITHUB_REPOSITORY"
release_json="$root/release.json"
verify_tag() {
  [[ "$(gh api "$api/commits/refs/tags/$tag" --jq .sha)" == "$GITHUB_SHA" ]] ||
    fail "Tag $tag does not point to the build commit."
}

# The releases list includes existing drafts, unlike the lookup by tag.
id=$(gh api --paginate "$api/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .id")
tag_ref=$(gh api "$api/git/matching-refs/tags/$tag" --jq ".[] | select(.ref == \"refs/tags/$tag\") | .ref")
if [[ -z "$tag_ref" ]]; then
  [[ -z "$id" ]] || fail "The existing release no longer has its tag."
  gh api --method POST "$api/git/refs" -f ref="refs/tags/$tag" -f sha="$GITHUB_SHA" --silent
fi
verify_tag
if [[ -z "$id" ]]; then
  # A new draft may not appear in the list immediately. Its creation returns the ID.
  id=$(gh api --method POST "$api/releases" --jq .id \
    -f tag_name="$tag" -f target_commitish="$GITHUB_SHA" -f name="$title" \
    -F "body=@$body_file" -F draft=true -F prerelease=true -f make_latest=false)
fi
[[ "$id" =~ ^[0-9]+$ ]] || fail "Expected one release for $tag."

read_release() {
  gh api "$api/releases/$id" > "$release_json"
  jq -e --arg tag "$tag" --rawfile notes "$body_file" '
    .tag_name == $tag and .prerelease == true and
    ((.body | sub("\n+$"; "")) == ($notes | sub("\n+$"; "")))
  ' "$release_json" >/dev/null || fail "Release tag, type or notes differ from the candidate."
}
verify_assets() {
  jq -e 'all(.assets[]; .state == "uploaded" and .size > 0)' "$release_json" >/dev/null
  diff -u <(for file in "${assets[@]}"; do
    printf '%s\t%s\n' "${file##*/}" "$(stat -c %s "$file")"
  done | sort) <(jq -r '.assets[] | [.name, .size] | @tsv' "$release_json" | sort)
}

read_release
if jq -e '.draft' "$release_json" >/dev/null; then
  # Retry interrupted uploads on the draft before making it visible.
  gh release upload "$tag" "${assets[@]}" --clobber
  read_release
  verify_assets
  verify_tag
  gh api --method PATCH "$api/releases/$id" -f name="$title" -F draft=false -f make_latest=false --silent
fi
read_release
jq -e --arg title "$title" '.draft == false and .published_at != null and .name == $title' "$release_json" >/dev/null
verify_tag
verify_assets
jq -r '.html_url' "$release_json"
