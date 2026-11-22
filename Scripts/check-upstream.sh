#!/usr/bin/env bash
# Compares Spec/pins.json with live upstream metadata and prints a Markdown report.
#
# SDE checks (0.1):
#   - a new release behind https://sde.evetech.net/tranquility/latest/
#   - changed version hashes for the pinned tables (or pinned tables that disappeared)
#   - _schemaChangelog entries for the pinned tables after the pinned build number
# ESI checks (compatibility dates, changelog) are added in 0.2.
#
# Usage: Scripts/check-upstream.sh [--pins <path>] [--sde-base-url <url>] [--dry-run]
#
# Exit codes: 0 = no changes, 10 = changes found (report on stdout), anything else = error.
# The script only reads public metadata. It never talks to GitHub; the upstream-watch workflow
# opens or updates the issue. `--dry-run` is accepted for symmetry and is always in effect.
# When $GITHUB_OUTPUT is set, it also writes `changed=<true|false>` and `sde_release=<release>`.
#
# Requires bash 3.2+, curl and jq.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="$script_dir/../Spec/pins.json"
sde_base="https://sde.evetech.net/tranquility/"
user_agent="CapsuleerKit-dev/0.1 (+https://github.com/Crazor/CapsuleerKit)"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pins) pins="$2"; shift 2 ;;
    --sde-base-url) sde_base="${2%/}/"; shift 2 ;;
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

# fetch <url> <output file>: GET with redirects, gzip, our User-Agent; fails on HTTP errors.
fetch() {
  if ! curl -fsSL --compressed --retry 2 --retry-delay 5 --max-time 120 \
      -A "$user_agent" -o "$2" "$1"; then
    echo "error: failed to fetch $1" >&2
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
  if $changed; then
    echo "**Changes found.** Update \`Spec/pins.json\` once the changes are handled."
  else
    echo "No changes."
  fi
}

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "changed=$changed"; echo "sde_release=$latest_release"; } >> "$GITHUB_OUTPUT"
fi

if $changed; then exit 10; fi
exit 0
