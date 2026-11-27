#!/usr/bin/env bash
set -euo pipefail

stage="$RUNNER_TEMP/avif-probe"
mkdir -p "$stage"
qjs="$stage/flutter_qjs/cxx/quickjs-ng"
revision=$(ruby -ryaml -e 'puts YAML.load_file("pubspec.lock").fetch("packages").fetch("flutter_qjs").fetch("description").fetch("resolved-ref")')
repo=$(ruby -ryaml -e 'puts YAML.load_file("pubspec.lock").fetch("packages").fetch("flutter_qjs").fetch("description").fetch("url")')
git init --quiet "$stage/flutter_qjs"
git -C "$stage/flutter_qjs" fetch --quiet --depth 1 "$repo" "$revision"
git -C "$stage/flutter_qjs" checkout --quiet --detach FETCH_HEAD

# Embed the actual app asset and the transparent fixture used by flutter test.
ruby -rbase64 -e '
  source = File.binread("assets/avif/decode.js")
  fixture = File.read("test/fixtures/avif_page.dart").split("transparentAvifPageBytes()", 2).fetch(1)
  sample = Base64.strict_decode64(fixture.scan(/\x27([^\x27]+)\x27/).flatten.join)
  puts "#include <stddef.h>"
  [["avif_decoder_source", "char", source], ["avif_fixture", "unsigned char", sample]].each do |name, type, bytes|
    puts "const #{type} #{name}[] = {"
    bytes.bytes.each_slice(32) { |row| puts row.join(",") + "," }
    puts "0};\nconst size_t #{name}_len = #{bytes.bytesize};"
  end
' > "$stage/data.c"

arch=$(uname -m)
for sdk in macosx iphonesimulator; do
  if [[ "$sdk" == macosx ]]; then target="$arch-apple-macos14.0"; else target="$arch-apple-ios15.1-simulator"; fi
  xcrun --sdk "$sdk" clang -O2 -std=gnu11 -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -I "$qjs" "-DCONFIG_VERSION=\"$(cat "$qjs/VERSION")\"" \
    "$qjs"/{quickjs,cutils,libunicode,libregexp,libbf}.c \
    tool/avif/apple_probe.c "$stage/data.c" -o "$stage/probe-$sdk"
done
"$stage/probe-macosx"
codesign --force --sign - "$stage/probe-iphonesimulator"
device=$(xcrun simctl list devices available -j | jq -er '[.devices | to_entries[] | select(.key | contains(".iOS-")) | .value[] | select(.isAvailable and (.name | startswith("iPhone")))] | first | .udid')
xcrun simctl bootstatus "$device" -b
xcrun simctl spawn "$device" "$stage/probe-iphonesimulator"
