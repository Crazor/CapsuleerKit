#!/usr/bin/env bash
# Compares Spec/pins.json with live upstream metadata and prints a Markdown report.
#
# SDE checks (0.1):
#   - a new release behind https://sde.evetech.net/tranquility/latest/
#   - changed version hashes for the pinned tables (or pinned tables that disappeared)
#   - _schemaChangelog entries for the pinned tables after the pinned build number
# ESI checks (0.2, when pins.json has an .esi section):
#   - compatibility dates newer than the pinned one (/meta/compatibility-dates)
#   - /meta/changelog entries after the pinned date for the pinned operations
#
# Usage: Scripts/check-upstream.sh [--pins <path>] [--sde-base-url <url>] [--esi-base-url <url>] [--dry-run]
#
# Exit codes: 0 = no changes, 10 = changes found (report on stdout), anything else = error.
# The script only reads public metadata. It never talks to GitHub; the upstream-watch workflow
# opens or updates the issue. `--dry-run` is accepted for symmetry and is always in effect.
# When $GITHUB_OUTPUT is set, it also writes `changed=<true|false>`, `sde_release=<release>` and `esi_date=<newest date>`.
#
# Requires bash 3.2+, curl and jq.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="$script_dir/../Spec/pins.json"
sde_base="https://sde.evetech.net/tranquility/"
esi_base="https://esi.evetech.net/"
user_agent="CapsuleerKit-dev/0.2 (+https://github.com/Crazor/CapsuleerKit)"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pins) pins="$2"; shift 2 ;;
    --sde-base-url) sde_base="${2%/}/"; shift 2 ;;
    --esi-base-url) esi_base="${2%/}/"; shift 2 ;;
    --dry-run) shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 3; }
done
[ -f "$pins" ] || { echo "error: pins file not found: $pins" >&2; exit 3; }
jq -e '.sde.release and .sde.buildNumber and (.sde.tables | type == "object")' "$pins" >/dev/null \
  || { echo "error: $pins has no valid .sde section" >&2; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/check-upstream.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# fetch <url> <output file> [extra curl args…]: GET with redirects, gzip, our User-Agent; fails on HTTP errors.
fetch() {
  local url="$1" out="$2"; shift 2
  if ! curl -fsSL --compressed --retry 2 --retry-delay 5 --max-time 120 \
      -A "$user_agent" "$@" -o "$out" "$url"; then
    echo "error: failed to fetch $url" >&2
    exit 4
  fi
}

# --- SDE ---------------------------------------------------------------------------------

fetch "${sde_base}latest/" "$work/manifest.json"
jq -e '.release and .buildNumber and (.tables | type == "object")' "$work/manifest.json" >/dev/null \
  || { echo "error: unexpected SDE manifest shape" >&2; exit 5; }

pinned_release="$(jq -r '.sde.release' "$pins")"
pinned_build="$(jq -r '.sde.buildNumber' "$pins")"
latest_release="$(jq -r '.release' "$work/manifest.json")"
latest_build="$(jq -r '.buildNumber' "$work/manifest.json")"
latest_date="$(jq -r '.releaseDate // "unknown"' "$work/manifest.json")"

# One row per pinned table: name, pinned hash, latest hash (empty if the table is gone).
jq -r --slurpfile m "$work/manifest.json" '
  .sde.tables | to_entries[] |
  [.key, .value, ($m[0].tables[.key].version // "")] | @tsv' "$pins" > "$work/tables.tsv"

# Schema changelog entries after the pinned build that touch a pinned table (by name or old name).
: > "$work/schema.md"
schema_url="$(jq -r '.tables._schemaChangelog.jsonl.url // empty' "$work/manifest.json")"
schema_note=""
if [ -n "$schema_url" ]; then
  fetch "$schema_url" "$work/schema.jsonl"
  jq -r -s --slurpfile p "$pins" '
    ($p[0].sde.buildNumber) as $build |
    ($p[0].sde.tables | keys) as $pinned |
    map(select(.afterBuildNumber >= $build)) | sort_by(.afterBuildNumber) | .[] |
    . as $entry |
    .tables[] | select((.table | IN($pinned[])) or ((.renamedFrom // "") | IN($pinned[]))) |
    "- **\(.table)**\(if .renamedFrom then " (renamed from `\(.renamedFrom)`)" else "" end)" +
    " (\($entry.date), after build \($entry.afterBuildNumber))" +
    (if .change then ": \(.change)" else "" end) +
    ([.fields[]? | "\n  - `\(.field)`" +
       (if .renamedFrom then ": renamed from `\(.renamedFrom)`" else "" end) +
       (if .change then ": \(.change)" else "" end)] | join(""))
  ' "$work/schema.jsonl" > "$work/schema.md"
else
  schema_note="The manifest lists no \`_schemaChangelog\` table, so schema changes were not checked."
fi

# --- ESI ---------------------------------------------------------------------------------

esi_enabled=false
esi_new_dates=""
esi_newest=""
: > "$work/esi-changes.md"
if jq -e '.esi.compatibilityDate and (.esi.operations | type == "array")' "$pins" >/dev/null 2>&1; then
  esi_enabled=true
  pinned_date="$(jq -r '.esi.compatibilityDate' "$pins")"
  fetch "${esi_base}meta/compatibility-dates" "$work/dates.json" -H "X-Compatibility-Date: $pinned_date"
  jq -e '.compatibility_dates | type == "array"' "$work/dates.json" >/dev/null \
    || { echo "error: unexpected ESI compatibility-dates shape" >&2; exit 5; }
  esi_newest="$(jq -r '.compatibility_dates | max' "$work/dates.json")"
  esi_new_dates="$(jq -r --arg d "$pinned_date" '[.compatibility_dates[] | select(. > $d)] | sort | join(", ")' "$work/dates.json")"
  # The changelog as seen with the newest date, so entries for newer dates are included.
  fetch "${esi_base}meta/changelog" "$work/changelog.json" -H "X-Compatibility-Date: $esi_newest"
  jq -r --slurpfile p "$pins" '
    ($p[0].esi.compatibilityDate) as $d | ($p[0].esi.operations) as $ops |
    .changelog | to_entries | map(select(.key > $d)) | sort_by(.key) | .[] | .key as $when |
    .value[] | select(("\(.method) \(.path)") | IN($ops[])) |
    "- **\(.method) \(.path)** (\($when), compatibility date \(.compatibility_date))" +
    (if (.type // "") != "" then ": " + .type else "" end) +
    (if (.description // "") != "" then " — " + .description else "" end)
  ' "$work/changelog.json" > "$work/esi-changes.md"
fi

# --- Report ------------------------------------------------------------------------------

changed=false
new_release=false
if [ "$latest_release" != "$pinned_release" ]; then new_release=true; changed=true; fi

table_rows=""
tables_changed=0
while IFS="$(printf '\t')" read -r name pinned latest; do
  if [ -z "$latest" ]; then
    status="**missing from the latest manifest**"; tables_changed=$((tables_changed + 1))
  elif [ "$latest" != "$pinned" ]; then
    status="**changed**"; tables_changed=$((tables_changed + 1))
  else
    status="unchanged"
  fi
  latest_cell="-"
  [ -n "$latest" ] && latest_cell="\`${latest:0:12}\`"
  table_rows="${table_rows}| \`${name}\` | \`${pinned:0:12}\` | ${latest_cell} | ${status} |
"
done < "$work/tables.tsv"
[ "$tables_changed" -gt 0 ] && changed=true
[ -s "$work/schema.md" ] && changed=true
[ -n "$esi_new_dates" ] && changed=true
[ -s "$work/esi-changes.md" ] && changed=true

{
  echo "# Upstream check"
  echo
  echo "## SDE"
  echo
  echo "- Pinned release: \`$pinned_release\` (build $pinned_build)"
  if $new_release; then
    echo "- Latest release: \`$latest_release\` (build $latest_build, released $latest_date): **new release**"
  else
    echo "- Latest release: \`$latest_release\` (build $latest_build): same as pinned"
  fi
  echo
  echo "### Pinned tables"
  echo
  echo "| Table | Pinned | Latest | Status |"
  echo "|---|---|---|---|"
  printf '%s' "$table_rows"
  echo
  echo "### Schema changelog for pinned tables after build $pinned_build"
  echo
  if [ -n "$schema_note" ]; then
    echo "$schema_note"
  elif [ -s "$work/schema.md" ]; then
    cat "$work/schema.md"
  else
    echo "No entries."
  fi
  echo
  if $esi_enabled; then
    echo "## ESI"
    echo
    echo "- Pinned compatibility date: \`$pinned_date\`"
    if [ -n "$esi_new_dates" ]; then
      echo "- Newer compatibility dates: **$esi_new_dates**"
    else
      echo "- Newest compatibility date: \`$esi_newest\`: same as pinned"
    fi
    echo
    echo "### Changelog for pinned operations after $pinned_date"
    echo
    if [ -s "$work/esi-changes.md" ]; then cat "$work/esi-changes.md"; else echo "No entries."; fi
    echo
  fi
  if $changed; then
    echo "**Changes found.** Update \`Spec/pins.json\` once the changes are handled."
  else
    echo "No changes."
  fi
}

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "changed=$changed"; echo "sde_release=$latest_release"; echo "esi_date=$esi_newest"; } >> "$GITHUB_OUTPUT"
fi

if $changed; then exit 10; fi
exit 0
