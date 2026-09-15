#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?GH_REPO is required}"

# The updater checks out main with all tags. A missing or older latest tag means
# the post-merge build/tag sequence has not finished; retry it on the next run.
released_sha=$(git rev-parse --verify --quiet 'refs/tags/latest^{}' || true)
if [ "$released_sha" != "$(git rev-parse HEAD)" ]; then
  gh workflow run build.yml --ref main
fi
