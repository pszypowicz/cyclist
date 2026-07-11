#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build Cyclist.app from the Swift package.

Usage: scripts/build-app.sh [--configuration debug|release] [--identity <substring|adhoc>] [--output <dir>]

Flags:
  --configuration  Swift build configuration: debug or release (default: release)
  --identity       Codesign identity, matched as a substring against
                   'security find-identity' output (default: "Apple Development").
                   Pass "adhoc" to ad-hoc sign; note that ad-hoc builds lose
                   the Accessibility grant on every rebuild.
  --output         Directory to place Cyclist.app in (default: build)
  -h, --help       Show this help.

Example:
  scripts/build-app.sh --configuration release
EOF
}

configuration=release
identity="Apple Development"
output=build

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) configuration="$2"; shift 2 ;;
    --identity) identity="$2"; shift 2 ;;
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
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$bin" "$app/Contents/MacOS/Cyclist"

if [[ "$identity" == "adhoc" ]]; then
  sign="-"
else
  # || true: with set -e, a failing security query (locked/absent keychain)
  # would abort here and skip the ad-hoc fallback below.
  sign="$(security find-identity -v -p codesigning | awk -v id="$identity" '$0 ~ id {print $2; exit}' || true)"
  if [[ -z "$sign" ]]; then
    echo "No codesigning identity matching '$identity'; falling back to ad-hoc." >&2
    sign="-"
  fi
fi

codesign --force --sign "$sign" "$app"
echo "Built $app"
