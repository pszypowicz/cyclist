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
                      Application", falling back to "Apple Development").
                      Pass "adhoc" to ad-hoc sign; note that ad-hoc builds lose
                      the Accessibility grant on every rebuild.
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
identity=""
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
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$bin" "$app/Contents/MacOS/Cyclist"

if [[ "$identity" == "adhoc" ]]; then
  sign="-"
else
  # Default preference order puts the release identity first: TCC grants
  # embed the signing certificate's requirements, so a dev build signed
  # with a different certificate than the installed release drops the
  # Accessibility grant on every swap.
  candidates=("Developer ID Application" "Apple Development")
  if [[ -n "$identity" ]]; then
    candidates=("$identity")
  fi
  sign=""
  for candidate in "${candidates[@]}"; do
    # || true: with set -e, a failing security query (locked/absent
    # keychain) would abort here and skip the ad-hoc fallback below.
    sign="$(security find-identity -v -p codesigning | awk -v id="$candidate" '$0 ~ id {print $2; exit}' || true)"
    if [[ -n "$sign" ]]; then
      break
    fi
  done
  if [[ -z "$sign" ]]; then
    echo "No codesigning identity matching '${candidates[*]}'; falling back to ad-hoc." >&2
    sign="-"
  fi
fi

sign_flags=()
if [[ "$hardened" == true ]]; then
  sign_flags+=(--options runtime --timestamp)
fi
# The ${arr[@]+...} form survives set -u on an empty array under bash 3.2.
codesign --force ${sign_flags[@]+"${sign_flags[@]}"} --sign "$sign" "$app"
echo "Built $app"
