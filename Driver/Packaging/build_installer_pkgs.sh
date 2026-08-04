#!/bin/bash
#
# build_installer_pkgs.sh — builds the install and uninstall .pkg packages
# for the AudioMixer virtual microphone driver.
#
# Usage:
#   Driver/Packaging/build_installer_pkgs.sh [output-dir]
#
# Environment variables (all optional; local development works without any
# of them, producing ad-hoc-signed packages suitable for testing on the
# machine that built them):
#   DRIVER_BUNDLE_PATH        Path to a pre-built AudioMixerVirtualDriver.driver.
#                              Defaults to building it via xcodebuild.
#   PKG_SIGNING_IDENTITY       "Developer ID Installer: ..." identity for
#                              `productbuild --sign`. If unset, packages are
#                              left unsigned (fine for local install/testing
#                              via Installer.app, NOT for distribution).
#   PKG_VERSION                Version string embedded in both packages.
#                              Defaults to the driver's CFBundleShortVersionString.
#
# Distribution builds must set PKG_SIGNING_IDENTITY to a valid "Developer ID
# Installer" certificate and notarize the resulting .pkg with
# `xcrun notarytool submit` + `xcrun stapler staple` — this script does not
# do that itself, since it requires credentials that must never be committed
# to the repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/build/Packaging}"

DRIVER_BUNDLE_NAME="AudioMixerVirtualDriver.driver"
DRIVER_IDENTIFIER="com.audiomixer.virtualdriver"
INSTALL_LOCATION="/Library/Audio/Plug-Ins/HAL"

mkdir -p "$OUTPUT_DIR"

if [ -z "${DRIVER_BUNDLE_PATH:-}" ]; then
    echo "Building $DRIVER_BUNDLE_NAME via xcodebuild..."
    BUILD_DIR="$OUTPUT_DIR/DriverBuild"
    xcodebuild -project "$REPO_ROOT/AudioMixer.xcodeproj" \
               -target AudioMixerVirtualDriver \
               -configuration Release \
               CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
               build
    DRIVER_BUNDLE_PATH="$BUILD_DIR/$DRIVER_BUNDLE_NAME"
fi

if [ ! -d "$DRIVER_BUNDLE_PATH" ]; then
    echo "error: driver bundle not found at $DRIVER_BUNDLE_PATH" >&2
    exit 1
fi

if [ -z "${PKG_VERSION:-}" ]; then
    PKG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DRIVER_BUNDLE_PATH/Contents/Info.plist")"
fi
echo "Packaging version $PKG_VERSION"

if [ -n "${CODE_SIGN_IDENTITY_DRIVER:-}" ]; then
    echo "Codesigning driver bundle with identity: $CODE_SIGN_IDENTITY_DRIVER"
    codesign --force --deep --options runtime --timestamp \
             --sign "$CODE_SIGN_IDENTITY_DRIVER" "$DRIVER_BUNDLE_PATH"
fi

#
# --- Install package -------------------------------------------------------
# Payload: the driver bundle itself, rooted at /Library/Audio/Plug-Ins/HAL.
#

INSTALL_PAYLOAD_ROOT="$OUTPUT_DIR/install-payload$INSTALL_LOCATION"
rm -rf "$OUTPUT_DIR/install-payload"
mkdir -p "$INSTALL_PAYLOAD_ROOT"
cp -R "$DRIVER_BUNDLE_PATH" "$INSTALL_PAYLOAD_ROOT/"

INSTALL_PKG_UNSIGNED="$OUTPUT_DIR/AudioMixerVirtualDriverInstaller-unsigned.pkg"
INSTALL_PKG="$OUTPUT_DIR/AudioMixerVirtualDriverInstaller.pkg"

pkgbuild --root "$OUTPUT_DIR/install-payload" \
         --identifier "$DRIVER_IDENTIFIER.pkg" \
         --version "$PKG_VERSION" \
         --scripts "$SCRIPT_DIR/scripts_install" \
         --install-location "/" \
         "$INSTALL_PKG_UNSIGNED"

if [ -n "${PKG_SIGNING_IDENTITY:-}" ]; then
    echo "Signing install package with identity: $PKG_SIGNING_IDENTITY"
    productbuild --package "$INSTALL_PKG_UNSIGNED" --sign "$PKG_SIGNING_IDENTITY" "$INSTALL_PKG"
    rm -f "$INSTALL_PKG_UNSIGNED"
else
    echo "warning: PKG_SIGNING_IDENTITY not set — producing an unsigned install package (local testing only)" >&2
    mv "$INSTALL_PKG_UNSIGNED" "$INSTALL_PKG"
fi

#
# --- Uninstall package ------------------------------------------------------
# No payload: the postinstall script alone performs the removal.
#

UNINSTALL_PKG_UNSIGNED="$OUTPUT_DIR/AudioMixerVirtualDriverUninstaller-unsigned.pkg"
UNINSTALL_PKG="$OUTPUT_DIR/AudioMixerVirtualDriverUninstaller.pkg"

pkgbuild --nopayload \
         --identifier "$DRIVER_IDENTIFIER.uninstall.pkg" \
         --version "$PKG_VERSION" \
         --scripts "$SCRIPT_DIR/scripts_uninstall" \
         "$UNINSTALL_PKG_UNSIGNED"

if [ -n "${PKG_SIGNING_IDENTITY:-}" ]; then
    productbuild --package "$UNINSTALL_PKG_UNSIGNED" --sign "$PKG_SIGNING_IDENTITY" "$UNINSTALL_PKG"
    rm -f "$UNINSTALL_PKG_UNSIGNED"
else
    mv "$UNINSTALL_PKG_UNSIGNED" "$UNINSTALL_PKG"
fi

rm -rf "$OUTPUT_DIR/install-payload"

echo "Built:"
echo "  $INSTALL_PKG"
echo "  $UNINSTALL_PKG"
