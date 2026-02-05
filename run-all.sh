#!/usr/bin/env bash

set -euo pipefail

ORG="jenkinsci"
LIMIT=3000
MATCH_PATTERN=""
dry_run=false
child_max_retries=""
child_initial_backoff=""
child_max_backoff=""
specific_repo=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGLE_REPO_SCRIPT="${SCRIPT_DIR}/script.sh"

usage() {
  cat <<'USAGE'
Usage: ./run-all.sh [options]

Iterates over repositories in an organization and runs script.sh for each one.

Options:
  --org               Organization name (default: jenkinsci)
  --limit             Maximum repositories to fetch (default: 3000)
  --match             Substring filter applied to repo nameWithOwner
  --repo              Process a single repository (owner/name)
  --dry-run           Pass through to script.sh dry-run mode
  --max-retries       Override script.sh retry count
  --initial-backoff   Override script.sh initial backoff (seconds)
  --max-backoff       Override script.sh maximum backoff (seconds)
  -h, --help          Show this help message
USAGE
}

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: Required command '$1' not found"
    exit 1
  }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --org)
        ORG="$2"
        shift 2
        ;;
      --limit)
        LIMIT="$2"
        shift 2
        ;;
      --match)
        MATCH_PATTERN="$2"
        shift 2
        ;;
      --repo)
        specific_repo="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --max-retries)
        child_max_retries="$2"
        shift 2
        ;;
      --initial-backoff)
        child_initial_backoff="$2"
        shift 2
        ;;
      --max-backoff)
        child_max_backoff="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log "ERROR: Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

require_cmd gh
require_cmd jq

[[ -f "$SINGLE_REPO_SCRIPT" ]] || {
  log "ERROR: script.sh not found at $SINGLE_REPO_SCRIPT"
  exit 1
}

repos=()

if [[ -n "$specific_repo" ]]; then
  repos+=("$specific_repo")
else
  repo_json=$(gh repo list "$ORG" --limit "$LIMIT" --json nameWithOwner,hasIssuesEnabled,isArchived) || {
    log "ERROR: Failed to list repositories for org $ORG"
    exit 1
  }
  mapfile -t repos < <(printf '%s' "$repo_json" | jq -r '.[] | select((.hasIssuesEnabled // false) == true and (.isArchived // false) == false) | .nameWithOwner')

  if [[ -n "$MATCH_PATTERN" ]]; then
    filtered=()
    for repo in "${repos[@]}"; do
      if [[ "$repo" == *"$MATCH_PATTERN"* ]]; then
        filtered+=("$repo")
      fi
    done
    repos=("${filtered[@]}")
  fi
fi

if (( ${#repos[@]} == 0 )); then
  log "No repositories to process"
  exit 0
fi

log "Processing ${#repos[@]} repositories"

child_args=()
if $dry_run; then
  child_args+=("--dry-run")
fi
if [[ -n "$child_max_retries" ]]; then
  child_args+=("--max-retries" "$child_max_retries")
fi
if [[ -n "$child_initial_backoff" ]]; then
  child_args+=("--initial-backoff" "$child_initial_backoff")
fi
if [[ -n "$child_max_backoff" ]]; then
  child_args+=("--max-backoff" "$child_max_backoff")
fi

failed_repos=()

child_cmd=("bash" "$SINGLE_REPO_SCRIPT")
for repo in "${repos[@]}"; do
  log "Running script.sh for $repo"
  if ! "${child_cmd[@]}" --repo "$repo" "${child_args[@]}"; then
    log "script.sh reported failures for $repo"
    failed_repos+=("$repo")
  fi
  # Brief pause to avoid hammering the API from orchestrator itself
  sleep 1
done

log "Completed run for ${#repos[@]} repositories"

if (( ${#failed_repos[@]} > 0 )); then
  log "Repositories with failures:"
  for failed_repo in "${failed_repos[@]}"; do
    log "  - $failed_repo"
  done
  exit 1
fi

log "All repositories completed without failures"

exit 0
