#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build a release Cyclist.app signed with Developer ID and the hardened
runtime, notarize it, staple the ticket, and produce the Cyclist.zip
release asset (rebuilt after stapling, so the asset carries the ticket).

Usage: scripts/notarize-release.sh [--keychain-profile <name>] [--output <dir>]

Flags:
  --keychain-profile  notarytool keychain profile with the notarization
                      credentials (default: cyclist-notary). Create once with:
                        xcrun notarytool store-credentials cyclist-notary \
                          --apple-id <apple-id> --team-id <team-id>
                      (prompts for an app-specific password from
                      account.apple.com > Sign-In and Security)
  --output            Directory for Cyclist.app and Cyclist.zip (default: build)
  -h, --help          Show this help.

Example:
  scripts/notarize-release.sh
EOF
}

profile=cyclist-notary
output=build

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keychain-profile) profile="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scripts/build-app.sh --configuration release \
  --identity "Developer ID Application" --hardened-runtime --output "$output"

app="$output/Cyclist.app"
zip="$output/Cyclist.zip"

# build-app.sh falls back to ad-hoc when the identity is missing; a release
# must never ship that way. Captured instead of piped to grep -q: under
# pipefail, grep's early exit SIGPIPEs codesign and fails the check on
# the very output it matched.
signature="$(codesign -dvv "$app" 2>&1)"
if [[ "$signature" != *"Authority=Developer ID Application"* ]]; then
  echo "error: $app is not signed with a Developer ID Application identity" >&2
  exit 1
fi

ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
# Stapling fails unless the submission was actually accepted, so a rejected
# notarization stops the script here.
xcrun stapler staple "$app"
rm "$zip"
ditto -c -k --keepParent "$app" "$zip"

spctl -a -vv "$app"
echo "Release asset: $zip"
shasum -a 256 "$zip"

# The DMG is packaged from the stapled app and notarized in its own right.
scripts/package-dmg.sh --app "$app" --output "$output/Cyclist.dmg" \
  --keychain-profile "$profile"
