#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?GH_REPO is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"

# Dispatching explicitly avoids the approval gate on GITHUB_TOKEN-created PRs.
# The API returns this run's ID so an older successful build cannot be selected.
run_id=$(gh api "repos/$GH_REPO/actions/workflows/build.yml/dispatches" \
  --method POST --header 'X-GitHub-Api-Version: 2026-03-10' \
  --raw-field ref=update-pi --jq '.workflow_run_id')
if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
  echo "Build dispatch did not return a workflow run ID." >&2
  exit 1
fi

gh run watch "$run_id" --exit-status --interval 15
built_sha=$(gh run view "$run_id" --json headSha --jq '.headSha')
if [ "$built_sha" != "$HEAD_SHA" ]; then
  echo "The dispatched build tested $built_sha, expected $HEAD_SHA." >&2
  exit 1
fi

# Keep GitHub's required checks enforced and refuse a changed PR head.
gh pr merge "$PR_NUMBER" --squash --delete-branch --match-head-commit "$HEAD_SHA"

# A merge performed with GITHUB_TOKEN does not trigger the push workflow.
# The successful main build will trigger Create Version Tag via workflow_run.
gh workflow run build.yml --ref main
