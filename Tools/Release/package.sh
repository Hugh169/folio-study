#!/bin/bash
# Builds Folio for release and packages it for GitHub Releases:
# build/release/Folio-<version>.dmg and Folio-<version>.dmg.sha256.
#
#   Tools/Release/package.sh [--sign <identity>] [--bundle-id <id>]
#
# --sign       the name of a code signing certificate in your keychain, such
#              as a self-signed one. Without it the app is signed ad hoc.
# --bundle-id  packages a test copy under another bundle ID, so installing it
#              starts from scratch and never shares data with your own Folio.
#              Its file name ends in -test.
#
# Folio isn't notarized, so people open it the first time from System
# Settings › Privacy & Security › Open Anyway. The script stops without
# packaging if the build has warnings, or the app has debug-only code, extra
# entitlements or no hardened runtime. Nothing is uploaded.
set -euo pipefail

identity="-"
test_bundle_id=""
while (( $# > 0 )); do
    case "$1" in
        --sign) identity="${2:?--sign needs a certificate name}"; shift 2 ;;
        --bundle-id) test_bundle_id="${2:?--bundle-id needs an ID}"; shift 2 ;;
        *) echo "usage: Tools/Release/package.sh [--sign <identity>] [--bundle-id <id>]" >&2; exit 2 ;;
    esac
done

repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="$repo/build/release"
derived="$out/DerivedData"
log="$out/build.log"
app="$derived/Build/Products/Release/Folio.app"

fail() { echo "✘ $*" >&2; exit 1; }

mkdir -p "$out"
echo "Building Release…"
if ! xcodebuild -project "$repo/Folio.xcodeproj" -scheme Folio -configuration Release \
    -derivedDataPath "$derived" -destination 'platform=macOS,arch=arm64' clean build > "$log" 2>&1; then
    tail -20 "$log" >&2
    fail "The build failed. The full log is in $log"
fi
if grep -E "(warning|error): " "$log" | sort -u | grep -q .; then
    grep -E "(warning|error): " "$log" | sort -u >&2
    fail "The build has warnings. Fix them before packaging."
fi

if [[ -n "$test_bundle_id" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $test_bundle_id" "$app/Contents/Info.plist"
fi
if [[ "$identity" != "-" || -n "$test_bundle_id" ]]; then
    echo "Signing$([[ "$identity" == "-" ]] && echo " ad hoc" || echo " with “$identity”")…"
    entitlements="$out/entitlements.plist"
    codesign -d --entitlements - --xml "$app" > "$entitlements" 2> /dev/null
    codesign --force --options runtime --timestamp=none --entitlements "$entitlements" --sign "$identity" "$app"
fi

echo "Checking the app…"
codesign --verify --strict "$app" || fail "The signature isn't valid."
# Each check reads its output in full: with pipefail, "grep -q" stopping
# early can make the command before it fail.
[[ "$(codesign -dv "$app" 2>&1)" == *"flags="*"runtime"* ]] || fail "Hardened runtime is off."

expected="com.apple.security.app-sandbox
com.apple.security.files.bookmarks.app-scope
com.apple.security.files.downloads.read-write
com.apple.security.files.user-selected.read-write
com.apple.security.network.client
com.apple.security.personal-information.calendars"
actual="$(codesign -d --entitlements - --xml "$app" 2> /dev/null | python3 -I -c 'import plistlib, sys; print("\n".join(sorted(k for k, v in plistlib.loads(sys.stdin.buffer.read()).items() if v)))')"
if [[ "$actual" != "$expected" ]]; then
    diff <(echo "$expected") <(echo "$actual") >&2 || true
    fail "The entitlements aren't the ones Folio needs (left: expected, right: in the app)."
fi

# The Debug-only self-test, renders, fresh start and click markers leave
# their type names in a binary that has them.
debug_types="$(strings -a "$app/Contents/MacOS/Folio" | grep -E -c "^(SelfTest|RenderShots|FreshStart|ShotTargets)$" || true)"
(( debug_types == 0 )) || fail "Debug-only code is in the Release build."
[[ -f "$app/Contents/Resources/PrivacyInfo.xcprivacy" ]] || fail "The privacy manifest is missing."

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"

echo "Packaging…"
name="Folio-$version"
if [[ -n "$test_bundle_id" ]]; then
    name+="-test"
fi
dmg="$out/$name.dmg"
staging="$out/dmg"
rm -rf "${staging:?}"
mkdir -p "$staging"
ditto "$app" "$staging/Folio.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg" "$dmg.sha256"
if ! diskutil image create from --format ULFO --volumeName "Folio $version" "$staging" "$dmg" > "$out/dmg.log" 2>&1; then
    cat "$out/dmg.log" >&2
    fail "Couldn't make the disk image."
fi
rm -rf "${staging:?}"
diskutil image info "$dmg" > /dev/null || fail "The disk image can't be read."
(cd "$out" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")

# The app on the disk image must still be valid.
mount_point="$out/mount"
diskutil image attach --readOnly --nobrowse --mountPoint "$mount_point" "$dmg" > /dev/null
verified=yes
codesign --verify --strict "$mount_point/Folio.app" || verified=no
diskutil eject "$mount_point" > /dev/null
[[ "$verified" == yes ]] || fail "The app on the disk image doesn't verify."

echo
echo "✔ Folio $version (build $build), $bundle_id, signed: $([[ "$identity" == "-" ]] && echo "ad hoc" || echo "$identity")"
echo "  $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
echo "  SHA-256 $(cut -d ' ' -f1 "$dmg.sha256")"
