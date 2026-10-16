#!/usr/bin/env bash
# Prints the Developer ID Application identity of a team that signs a
# release: its SHA-1 hash, a tab, its name, for VOXTNEW_SIGN_IDENTITY
# (scripts/release.sh, docs/release.md). Sign with the hash: codesign refuses a name
# that two certificates share ("ambiguous"), as a renewed certificate and
# the old one do, and a keychain may hold the identities of several teams,
# such as the Mac where the certificate is exported from (docs/release.md).
#
#   scripts/release-identity.sh TEAMID [KEYCHAIN]
#
# It fails when the team has no valid Developer ID Application identity,
# listing those it saw (names only).
set -euo pipefail

team="${1:?the Team ID, e.g. 779M533DL5}"
keychain="${2:-}"
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "release-identity.sh: $team is not a Team ID (10 letters and digits)" >&2
  exit 2
fi
list="$(security find-identity -v -p codesigning ${keychain:+"$keychain"})"
# Lines such as:   1) 0123…ABCD "Developer ID Application: Name (TEAMID)"
match="$(sed -nE "s/^ *[0-9]+\) ([0-9A-F]{40}) \"(Developer ID Application: .* \($team\))\"\$/\1	\2/p" <<<"$list")"
if [[ -z "$match" ]]; then
  echo "release-identity.sh: no valid Developer ID Application identity of the team $team; found:" >&2
  sed -nE 's/^ *[0-9]+\) [0-9A-F]{40} (".*")$/  \1/p' <<<"$list" >&2
  exit 1
fi
if (($(wc -l <<<"$match") > 1)); then
  echo "release-identity.sh: $(wc -l <<<"$match" | tr -d ' ') identities of the team $team; signing with the first" >&2
fi
head -1 <<<"$match"
