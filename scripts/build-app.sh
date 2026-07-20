#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build Cyclist.app from the Swift package.

Usage: scripts/build-app.sh [--configuration debug|release] [--identity <substring|adhoc>] [--hardened-runtime] [--output <dir>]

Flags:
  --configuration     Swift build configuration: debug or release (default: release)
  --identity          Codesign identity, matched as a substring against
                      'security find-identity' output (default: "Developer ID
                      Application", the release identity - builds signed with
                      it keep the TCC Accessibility grant across release
                      installs). No fallback: a missing match is a hard error,
                      never a silently different signature. Pass "adhoc" to
                      ad-hoc sign; note that ad-hoc builds lose the
                      Accessibility grant on every rebuild.
  --hardened-runtime  Sign with the hardened runtime and a secure timestamp,
                      as notarization requires. Needs network (timestamp
                      service) and a real identity.
  --output            Directory to place Cyclist.app in (default: build)
  -h, --help          Show this help.

Example:
  scripts/build-app.sh --configuration release
EOF
}

configuration=release
identity="Developer ID Application"
hardened=false
output=build

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) configuration="$2"; shift 2 ;;
    --identity) identity="$2"; shift 2 ;;
    --hardened-runtime) hardened=true; shift ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$configuration" in
  debug|release) ;;
  *) echo "Invalid --configuration: $configuration (expected debug or release)" >&2; exit 1 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift build --configuration "$configuration"
bin="$(swift build --configuration "$configuration" --show-bin-path)/Cyclist"

app="$output/Cyclist.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Stamp the bundle version from VERSION, the single source of truth. The
# plist ships with a __VERSION__ placeholder so no build carries a stale
# hardcoded number; the BuildMetadata plugin reads the same file.
version=$(head -1 VERSION 2>/dev/null | tr -d '[:space:]')
[ -n "$version" ] || { echo "error: VERSION file missing or empty" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$bin" "$app/Contents/MacOS/Cyclist"

if [[ "$identity" == "adhoc" ]]; then
  sign="-"
else
  # || true: with set -e, a failing security query (locked/absent
  # keychain) would abort before the explicit error below.
  sign="$(security find-identity -v -p codesigning | awk -v id="$identity" '$0 ~ id {print $2; exit}' || true)"
  if [[ -z "$sign" ]]; then
    echo "error: no codesigning identity matching '$identity'" >&2
    echo "List identities with: security find-identity -v -p codesigning" >&2
    echo "Pick one with --identity <substring>, or --identity adhoc for an unsigned dev build." >&2
    exit 1
  fi
fi

sign_flags=()
if [[ "$hardened" == true ]]; then
  sign_flags+=(--options runtime --timestamp)
fi
# The ${arr[@]+...} form survives set -u on an empty array under bash 3.2.
codesign --force ${sign_flags[@]+"${sign_flags[@]}"} --sign "$sign" "$app"
echo "Built $app"
