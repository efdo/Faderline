#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash scripts/package-app.sh --version X.Y.Z [--build-number N]
       [--output DIRECTORY] --unsigned-development
   or: bash scripts/package-app.sh --version X.Y.Z [--build-number N]
       [--output DIRECTORY] --developer-id "Developer ID Application: Name (TEAMID)"
       --notary-profile PROFILE

Builds only Faderline.app (Release, arm64, macOS 15+) and a read-only DMG
with an Applications shortcut and SHA-256 checksum. No installation occurs.
Choose a signing mode explicitly; missing credentials never fall back to unsigned.
Default build number: 1. Default output directory: <repository>/dist.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

version=
build_number=1
output=
mode=
identity=
notary_profile=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--build-number|--output|--developer-id|--notary-profile)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Missing value for $1"
            case "$1" in
                --version) version="$2" ;;
                --build-number) build_number="$2" ;;
                --output) output="$2" ;;
                --developer-id)
                    [[ -z "$mode" ]] || fail "Choose exactly one signing mode"
                    mode=developer-id-notarized
                    identity="$2"
                    ;;
                --notary-profile) notary_profile="$2" ;;
            esac
            shift 2
            ;;
        --unsigned-development)
            [[ -z "$mode" ]] || fail "Choose exactly one signing mode"
            mode=unsigned-development
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1 (use --help)" ;;
    esac
done

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || fail "--version must be a numeric X.Y.Z version without a v prefix"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "--build-number must be a positive integer"
[[ -n "$mode" ]] || fail "Choose --unsigned-development or --developer-id explicitly"
if [[ "$mode" == unsigned-development ]]; then
    [[ -z "$notary_profile" ]] || fail "--notary-profile requires --developer-id"
else
    [[ "$identity" == "Developer ID Application: "* ]] \
        || fail "Public distribution requires a Developer ID Application identity"
    [[ -n "$notary_profile" ]] || fail "--developer-id requires --notary-profile"
fi
[[ "$(uname -s)" == Darwin ]] || fail "Packaging requires macOS and full Xcode"
for tool in xcodebuild hdiutil codesign ditto shasum; do
    command -v "$tool" >/dev/null || fail "Required tool is unavailable: $tool"
done
if [[ "$mode" == developer-id-notarized ]]; then
    security find-identity -v -p codesigning | grep -F "\"$identity\"" >/dev/null \
        || fail "Signing identity is unavailable: $identity"
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
    xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null
fi

root="$(cd "$(dirname "$0")/.." && pwd -P)"
output="${output:-$root/dist}"
mkdir -p "$output" "$root/.build"
output="$(cd "$output" && pwd -P)"
base="Faderline-$version-arm64-$mode"
destination="$output/$base"
[[ ! -e "$destination" ]] || fail "Output already exists: $destination (choose another --output)"
work="$(mktemp -d "$root/.build/release-packaging.XXXXXX")"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        if ! hdiutil detach "$work/mount" -quiet; then
            echo "error: Could not detach $work/mount; temporary files retained at $work" >&2
            return 1
        fi
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Building Faderline $version ($build_number), arm64, $mode"
xcodebuild -quiet build \
    -project "$root/Faderline.xcodeproj" -scheme Faderline \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$work/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=15.0 \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGNING_ALLOWED=NO

mkdir -p "$work/artifacts" "$work/image"
app="$work/artifacts/Faderline.app"
ditto "$work/DerivedData/Build/Products/Release/Faderline.app" "$app"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]] \
    || fail "Built app version does not match $version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build_number" ]] \
    || fail "Built app build number does not match $build_number"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == com.faderline.app ]] \
    || fail "Unexpected app bundle identifier"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == 15.0 ]] \
    || fail "Unexpected minimum macOS version"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$plist")" ]] \
    || fail "App is missing its microphone permission description"
[[ "$(lipo -archs "$app/Contents/MacOS/Faderline")" == arm64 ]] \
    || fail "The packaged executable must contain only arm64"

notarize() {
    local artifact="$1"
    local result="$2"
    xcrun notarytool submit "$artifact" --keychain-profile "$notary_profile" \
        --wait --output-format plist > "$result"
    local status
    status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$result")"
    if [[ "$status" != Accepted ]]; then
        cat "$result" >&2
        fail "Notarization was not accepted; use the submission ID above to retrieve the notarytool log"
    fi
}

if [[ "$mode" == unsigned-development ]]; then
    # Apple Silicon needs an ad-hoc signature; this is not a Developer ID signature.
    codesign --force --sign - --timestamp=none "$app"
    signing_note="UNSIGNED DEVELOPMENT ARTIFACT: ad-hoc signed only, NOT Developer ID signed or notarized. Gatekeeper may block it. Use only for trusted development."
else
    codesign --force --sign "$identity" --options runtime --timestamp \
        --entitlements "$root/scripts/DeveloperID.entitlements" "$app"
    codesign --display --verbose=4 "$app" 2> "$work/app-signature.txt"
    grep -Fx "Authority=$identity" "$work/app-signature.txt" >/dev/null \
        || fail "The app was not signed with the requested Developer ID identity"
    codesign --display --entitlements - --xml "$app" > "$work/app-entitlements.plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' \
        "$work/app-entitlements.plist")" == true ]] \
        || fail "The hardened-runtime app is missing its Audio Input entitlement"
    ditto -c -k --keepParent "$app" "$work/notarization.zip"
    notarize "$work/notarization.zip" "$work/app-notarization.plist"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
    signing_note="Developer ID Application signed and Apple notarized. Notarization tickets are stapled to both the app and disk image."
fi
codesign --verify --deep --strict --verbose=2 "$app"

ditto "$app" "$work/image/Faderline.app"
ln -s /Applications "$work/image/Applications"
cat > "$work/image/README.txt" <<EOF
Faderline $version (build $build_number) - macOS 15+ / Apple Silicon only

$signing_note

Install: drag Faderline.app to the Applications shortcut.
Update: quit Faderline cleanly with Command-Q and wait for it to exit, then
replace Faderline.app in Applications. Never force-kill a running mixer.
Eject this disk image, then open the app from Applications.

This image contains only the mixer app. It does not include, install,
update, or remove a virtual microphone driver. Updates are manual.
EOF

dmg="$work/artifacts/$base.dmg"
hdiutil create -quiet -volname "$base" -srcfolder "$work/image" \
    -fs HFS+ -format UDZO "$dmg"
if [[ "$mode" == developer-id-notarized ]]; then
    codesign --sign "$identity" --timestamp "$dmg"
    notarize "$dmg" "$work/dmg-notarization.plist"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    codesign --verify --strict --verbose=2 "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

hdiutil verify -quiet "$dmg"
mkdir "$work/mount"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$work/mount" "$dmg"
mounted=true
[[ "$(readlink "$work/mount/Applications")" == /Applications ]] \
    || fail "DMG Applications shortcut is invalid"
cmp "$plist" "$work/mount/Faderline.app/Contents/Info.plist"
diff -qr "$app" "$work/mount/Faderline.app"
cmp "$work/image/README.txt" "$work/mount/README.txt"
codesign --verify --deep --strict --verbose=2 "$work/mount/Faderline.app"
echo "Verified DMG contents:"
ls -A "$work/mount"
hdiutil detach -quiet "$work/mount"
mounted=false

(cd "$work/artifacts" && shasum -a 256 "$base.dmg" > "$base.sha256" \
    && shasum -a 256 -c "$base.sha256")
mv "$work/artifacts" "$destination"
echo "Packaged: $destination"
echo "$signing_note"
