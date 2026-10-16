#!/usr/bin/env bash
# Turns mygo.json, in place, into the configuration of a release build:
# the updates of release/mygo.release.json (the public key that installed
# apps check updates against, and the GitHub repository of the releases),
# and for a Developer ID build the signing identity and the notary
# profile. The release workflow runs it (.github/workflows/release.yml),
# and the update test with an overlay of its own
# (scripts/mac-update-e2e.sh); `git checkout mygo.json` undoes it.
#
# mygo.json itself has no `updates`: every `mygo build` with them can
# update itself (MyGo links the feed in), and would replace a test build on
# the Mac with the published release. See docs/release.md.
#
#   scripts/release-config.sh                                   # updates only
#   scripts/release-config.sh --sign "Developer ID Application: … (TEAMID)" \
#     --notary-keychain "$RUNNER_TEMP/signing.keychain-db"      # CI
#   scripts/release-config.sh --overlay FILE                    # other updates
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$ROOT/release/mygo.release.json"
sign="" keychain="" profile="notary"
while (($#)); do
  case "$1" in
    --overlay) overlay="$2"; shift 2 ;;
    --sign) sign="$2"; shift 2 ;;
    --notary-keychain) keychain="$2"; shift 2 ;;
    --notary-profile) profile="$2"; shift 2 ;;
    *) echo "release-config.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null || { echo "release-config.sh needs jq" >&2; exit 1; }
[[ -f "$overlay" ]] || { echo "no overlay $overlay" >&2; exit 1; }
if [[ -n "$keychain" && -z "$sign" ]]; then
  echo "notarization needs a Developer ID: pass --sign" >&2
  exit 2
fi

cfg="$ROOT/mygo.json"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
jq --slurpfile o "$overlay" --arg sign "$sign" --arg keychain "$keychain" --arg profile "$profile" '
  . * $o[0]
  | if $sign != "" then .macos.signingIdentity = $sign else . end
  | if $keychain != "" then .macos.notarize = {keychainProfile: $profile, keychain: $keychain} else . end
' "$cfg" >"$tmp"
jq -e '.updates.publicKey and (.updates.github or .updates.url)' "$tmp" >/dev/null ||
  { echo "the overlay gives no updates.publicKey with github or url" >&2; exit 1; }
cat "$tmp" >"$cfg"
echo "mygo.json: updates from $(basename "$overlay")${sign:+, signed by $sign}${keychain:+, notarized with the profile $profile}"
