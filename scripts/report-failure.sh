#!/usr/bin/env bash
set -euo pipefail

usage="usage: report-failure.sh <label> <title-prefix> <title> <head-file> <log-file>"
label="${1:?$usage}"
prefix="${2:?$usage}"
title="${3:?$usage}"
head_file="${4:?$usage}"
log_file="${5:?$usage}"
for f in "$head_file" "$log_file"; do
  [ -r "$f" ] || {
    echo "report-failure.sh: cannot read $f" >&2
    exit 1
  }
done

run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?}/actions/runs/${GITHUB_RUN_ID:?}"
today=$(date -u +%F)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed 's/\x1b\[[0-9;]*m//g' "$log_file" | cut -c1-300 >"$work/plain"

log_section() {
  if [ -n "${FAILED_ATTRS:-}" ] || [ -n "${FAILED_DRVS:-}" ]; then
    printf '\n### Failing targets\n\n```\n'
    if [ -n "${FAILED_ATTRS:-}" ]; then printf '%s\n' "$FAILED_ATTRS" | tr ' ' '\n'; fi
    if [ -n "${FAILED_DRVS:-}" ]; then printf '%s\n' "$FAILED_DRVS" | tr ' ' '\n'; fi
    printf '```\n'
  fi
  local at
  if at=$(grep -n -m1 -E '^(\S+> )?\s*error(\[E[0-9]+\])?:' "$work/plain"); then
    at="${at%%:*}"
    printf '\n<details open><summary>First error</summary>\n\n```\n'
    sed -n "${at},$((at + 24))p" "$work/plain"
    printf '```\n</details>\n'
  fi
  printf '\n<details><summary>Log, last 100 lines</summary>\n\n```\n'
  tail -n 100 "$work/plain"
  printf '```\n</details>\n'
}

gh_retry() {
  local attempt out
  for attempt in 1 2 3; do
    if out=$(gh "$@"); then
      printf '%s' "$out"
      return 0
    fi
    echo "report-failure.sh: gh $1 $2 failed (attempt $attempt of 3)" >&2
    if [ "$attempt" -lt 3 ]; then sleep $((attempt * ${REPORT_RETRY_DELAY:-10})); fi
  done
  return 1
}

open=$(gh_retry issue list --label "$label" --state open --limit 100 --json number,title,createdAt)
mapfile -t same < <(jq -r --arg p "$prefix" \
  '[.[] | select(.title | startswith($p))] | sort_by(.number)[] | [.number, .createdAt[0:10], .title] | @tsv' <<<"$open")

if [ "${#same[@]}" -eq 0 ]; then
  {
    printf 'First reported on %s by %s\n\n' "$today" "$run_url"
    cat "$head_file"
    log_section
  } >"$work/body"
  url=$(gh_retry issue create --label "$label" --title "$title" --body-file "$work/body")
  number="${url##*/}"
else
  IFS=$'\t' read -r number since old_title <<<"${same[0]}"
  for extra in "${same[@]:1}"; do
    gh_retry issue close "${extra%%$'\t'*}" --reason "not planned" --comment "The same failure is tracked in #$number." >/dev/null
  done
  days=$((($(date -u -d "$today" +%s) - $(date -u -d "$since" +%s)) / 86400))
  {
    printf 'Open since %s (%s days); no run has succeeded since. Latest failing run on %s: %s\n\n' "$since" "$days" "$today" "$run_url"
    cat "$head_file"
    log_section
  } >"$work/body"
  gh_retry issue edit "$number" --title "$title" --body-file "$work/body" >/dev/null
  if [ "$title" != "$old_title" ]; then
    gh_retry issue comment "$number" --body "Now reported as: $title (previously: $old_title). Run: $run_url" >/dev/null
  fi
fi

[[ "$number" =~ ^[0-9]+$ ]] || {
  echo "report-failure.sh: gh returned no issue number ('$number')" >&2
  exit 1
}
echo "number=$number" >>"${GITHUB_OUTPUT:-/dev/stdout}"
