#!/usr/bin/env bash

set -euo pipefail

OLD_PREFIXES=(
	"https://raw.githubusercontent.com/jenkinsci/attachments-from-jira-issues-misc/refs/heads/main/attachments"
	"https://raw.githubusercontent.com/jenkinsci/attachments-from-jira-issues-last/refs/heads/main/attachments"
    "https://raw.githubusercontent.com/jenkinsci/attachments-from-jira-issues-core-cli/refs/heads/main/attachments"
)
NEW_PREFIX="https://issues.jenkins.io/secure/attachment"
TARGET_LABEL="imported-jira-issue"

repo=""
dry_run=false
max_retries=5
initial_backoff=2
max_backoff=60

usage() {
	cat <<'USAGE'
Usage: ./script.sh --repo <owner/repo> [--dry-run] [--max-retries N] [--initial-backoff SECONDS] [--max-backoff SECONDS]

Updates issue descriptions that contain legacy attachment URLs for the given repository.

Options:
	--repo              Repository in owner/name form (required)
	--dry-run           Show planned updates without editing issues
	--max-retries       Number of retry attempts for GitHub API calls (default: 5)
	--initial-backoff   Initial backoff delay in seconds (default: 2)
	--max-backoff       Maximum backoff delay in seconds (default: 60)
	-h, --help          Show this help message
USAGE
}

log() {
	printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
	log "ERROR: $*"
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found"
}

run_with_retry() {
	local capture_var=$1
	shift
	local attempt=1
	local delay=$initial_backoff
	local output status

	while true; do
		set +e
		output=$("$@" 2>&1)
		status=$?
		set -e

		if [[ $status -eq 0 ]]; then
			if [[ -n $capture_var ]]; then
				printf -v "$capture_var" '%s' "$output"
			fi
			return 0
		fi

		if (( attempt >= max_retries )); then
			printf '%s\n' "$output" >&2
			return $status
		fi

		log "Command failed (attempt ${attempt}/${max_retries}). Retrying in ${delay}s..."
		sleep "$delay"
		attempt=$((attempt + 1))
		delay=$((delay * 2))
		if (( delay > max_backoff )); then
			delay=$max_backoff
		fi
	done
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--repo)
				repo="$2"
				shift 2
				;;
			--dry-run)
				dry_run=true
				shift
				;;
			--max-retries)
				max_retries="$2"
				shift 2
				;;
			--initial-backoff)
				initial_backoff="$2"
				shift 2
				;;
			--max-backoff)
				max_backoff="$2"
				shift 2
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "Unknown argument: $1"
				;;
		esac
	done
}

parse_args "$@"

[[ -n "$repo" ]] || die "--repo is required"

require_cmd gh
require_cmd jq

log "Processing repository $repo"

issue_list_json=""
if ! run_with_retry issue_list_json gh issue list -R "$repo" --limit 20000 --state=all --label "$TARGET_LABEL" --json number; then
	die "Failed to list issues for $repo"
fi

mapfile -t issue_numbers < <(printf '%s' "$issue_list_json" | jq -r '.[].number')

if (( ${#issue_numbers[@]} == 0 )); then
	log "No matching issues found in $repo"
	exit 0
fi

log "Found ${#issue_numbers[@]} labeled issues in $repo"

updated_count=0
skipped_count=0
error_count=0

for issue_number in "${issue_numbers[@]}"; do
	issue_url="https://github.com/$repo/issues/$issue_number"
	log "Inspecting issue #$issue_number"
	issue_json=""
	if ! run_with_retry issue_json gh api "repos/$repo/issues/$issue_number"; then
		log "Failed to fetch issue #$issue_number"
		((error_count+=1))
		continue
	fi

	body=$(printf '%s' "$issue_json" | jq -r '.body // ""')

	if [[ -z "$body" ]]; then
		log "Issue #$issue_number has empty body, skipping"
		((skipped_count+=1))
		continue
	fi

	updated_body="$body"
	for old_prefix in "${OLD_PREFIXES[@]}"; do
		updated_body=${updated_body//$old_prefix/$NEW_PREFIX}
	done

	if [[ "$updated_body" == "$body" ]]; then
		log "Issue #$issue_number does not contain target URL, skipping"
		((skipped_count+=1))
		continue
	fi

	if $dry_run; then
		log "[dry-run] Would update $issue_url"
		((updated_count+=1))
		continue
	fi

	tmpfile=$(mktemp)
	printf '%s' "$updated_body" > "$tmpfile"
	if run_with_retry "" gh issue edit -R "$repo" "$issue_number" --body-file "$tmpfile"; then
		log "Updated $issue_url"
		((updated_count+=1))
	else
		log "Failed to update $issue_url"
		((error_count+=1))
	fi
	rm -f "$tmpfile"
done

log "Completed repository $repo"
log "Updated: $updated_count | Skipped: $skipped_count | Errors: $error_count"

if (( error_count > 0 )); then
	exit 1
fi

exit 0
