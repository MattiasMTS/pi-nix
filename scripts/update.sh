#!/usr/bin/env bash
# Sync install-lock/ with the lockfile the official pi.dev installer uses for
# managed installs, so the Nix build resolves the exact same dependency tree.
set -euo pipefail

API="${PI_INSTALLER_API_BASE:-https://pi.dev/api/installer/releases}"
PI_PACKAGE="@earendil-works/pi-coding-agent"
LOCK_DIR="install-lock"

log() { echo "[INFO] $*"; }
die() {
	echo "[ERROR] $*" >&2
	exit 2
}

usage() {
	cat <<'USAGE'
Usage: scripts/update.sh [--check] [--version VERSION]

  --check            Only check; exits 1 when an update is available
  --version VERSION  Sync to a specific Pi version instead of latest
USAGE
}

cd "$(dirname "$0")/.."
for tool in curl jq nix; do
	command -v "$tool" >/dev/null || die "$tool is required"
done

check_only=false
target=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--check) check_only=true && shift ;;
	--version) target="${2:?--version requires a value}" && shift 2 ;;
	--help) usage && exit 0 ;;
	*) usage >&2 && exit 2 ;;
	esac
done

current=$(jq -r .version "$LOCK_DIR/package.json" 2>/dev/null || echo none)
metadata=$(curl -fsSL "$API/${target:-latest}") || die "Failed to fetch release metadata"
latest=$(jq -r .version <<<"$metadata")
[ -n "$latest" ] && [ "$latest" != null ] || die "Release metadata has no version"

log "Current version: $current"
log "Latest version: $latest"
if [ "$current" = "$latest" ]; then
	log "Already up to date!"
	exit 0
fi
if [ "$check_only" = true ]; then
	log "Update available: $current → $latest"
	exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$API/$latest/package.json" -o "$tmp/package.json"
curl -fsSL "$API/$latest/package-lock.json" -o "$tmp/package-lock.json"

# Same validation the installer runs before trusting the artifacts.
jq -e --arg pkg "$PI_PACKAGE" --arg v "$latest" '
  .lockfileVersion == 3
  and .packages[""].dependencies[$pkg] == $v
  and .packages["node_modules/\($pkg)"].version == $v
' "$tmp/package-lock.json" >/dev/null || die "Installer lockfile does not describe $PI_PACKAGE@$latest"

# The lock omits integrity for pi's own packages; the release metadata pins them.
jq --tab --argjson meta "$metadata" '
  ($meta.packages | map({key: .tarball, value: .integrity}) | from_entries) as $pinned
  | .packages |= with_entries(
      if .value.integrity == null and $pinned[.value.resolved // ""] then
        .value.integrity = $pinned[.value.resolved]
      else . end)
' "$tmp/package-lock.json" >"$tmp/hydrated.json"

missing=$(jq -r '
  .packages | to_entries[]
  | select(.key != "" and .value.link != true and .value.integrity == null)
  | .key
' "$tmp/hydrated.json")
[ -z "$missing" ] || die "Lockfile entries without integrity: $missing"

mkdir -p "$LOCK_DIR"
cp "$tmp/package.json" "$LOCK_DIR/package.json"
cp "$tmp/hydrated.json" "$LOCK_DIR/package-lock.json"

log "Verifying build..."
out=$(nix build .#pi-coding-agent --no-link --print-out-paths --print-build-logs)
"$out/bin/pi" --version
log "Updated pi-coding-agent to $latest ($(jq -r .sourceCommit <<<"$metadata"))"
