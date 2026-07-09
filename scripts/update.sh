#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE_NAME="@earendil-works/pi-coding-agent"
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

get_current_version() {
  sed -n 's/.*version = "\([^"]*\)".*/\1/p' package.nix | head -1 || echo "unknown"
}

fetch_npm_version() {
  if command -v npm >/dev/null 2>&1; then
    npm view "$NPM_PACKAGE_NAME" version 2>/dev/null
  elif command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 10 "$NPM_REGISTRY_URL/$NPM_PACKAGE_NAME/latest" \
      | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
  else
    return 1
  fi
}

get_latest_version() {
  local version
  version=$(fetch_npm_version || true)
  if [ -z "$version" ]; then
    log_error "Failed to fetch latest version for $NPM_PACKAGE_NAME"
    exit 2
  fi
  echo "$version"
}

set_version() {
  local version="$1"
  sed -i.bak -E "s/version = \"[^\"]+\"/version = \"$version\"/" package.nix
}

set_source_hash() {
  local hash="$1"
  local temp_file
  temp_file=$(mktemp)

  awk -v hash="$hash" '
    /src = fetchFromGitHub \{/ { in_src=1 }
    in_src && /hash = / {
      sub(/hash = "[^"]+"/, "hash = \"" hash "\"")
      in_src=0
    }
    { print }
  ' package.nix > "$temp_file"
  mv "$temp_file" package.nix
}

set_npm_deps_hash() {
  local hash="$1"
  sed -i.bak -E "s/npmDepsHash = \"[^\"]+\"/npmDepsHash = \"$hash\"/" package.nix
}

extract_got_hash() {
  sed -nE 's/^[[:space:]]*got:[[:space:]]+(sha256-[A-Za-z0-9+\/=]+).*/\1/p' | tail -1
}

prefetch_hash_from_nix_mismatch() {
  local label="$1"
  local output
  local status

  set +e
  output=$(nix build .#pi-coding-agent --no-link 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    log_error "Expected a fixed-output hash mismatch while prefetching $label, but nix build succeeded."
    return 1
  fi

  local hash
  hash=$(printf '%s\n' "$output" | extract_got_hash)
  if [ -z "$hash" ]; then
    log_error "Could not extract computed $label hash from nix output:"
    printf '%s\n' "$output" >&2
    return 1
  fi

  printf '%s\n' "$hash"
}

cleanup_backup_files() {
  rm -f package.nix.bak
}

rollback_package() {
  if [ -f package.nix.bak ]; then
    mv package.nix.bak package.nix
  fi
}

update_to_version() {
  local new_version="$1"

  log_info "Updating pi-coding-agent to version $new_version..."

  cp package.nix package.nix.bak
  trap rollback_package ERR

  set_version "$new_version"

  log_info "Prefetching source hash..."
  set_source_hash "$FAKE_HASH"
  set_npm_deps_hash "$FAKE_HASH"
  local source_hash
  source_hash=$(prefetch_hash_from_nix_mismatch "source")
  log_info "  source: $source_hash"
  set_source_hash "$source_hash"

  log_info "Prefetching npm dependency hash..."
  local npm_hash
  npm_hash=$(prefetch_hash_from_nix_mismatch "npmDeps")
  log_info "  npmDepsHash: $npm_hash"
  set_npm_deps_hash "$npm_hash"

  cleanup_backup_files
  trap - ERR

  if command -v nixfmt >/dev/null 2>&1; then
    nixfmt package.nix flake.nix || true
  elif command -v nixfmt-rfc-style >/dev/null 2>&1; then
    nixfmt-rfc-style package.nix flake.nix || true
  fi

  log_info "Updating flake.lock..."
  nix flake update

  log_info "Verifying build..."
  nix build .#pi-coding-agent -o result --print-build-logs
  ./result/bin/pi --version

  log_info "Successfully updated pi-coding-agent to $new_version"
}

ensure_in_repository_root() {
  if [ ! -f "flake.nix" ] || [ ! -f "package.nix" ]; then
    log_error "flake.nix or package.nix not found. Run this script from the repository root."
    exit 2
  fi
}

ensure_required_tools_installed() {
  command -v nix >/dev/null 2>&1 || { log_error "nix is required but not installed."; exit 2; }
  if ! command -v npm >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    log_error "npm or curl is required to fetch the latest version."
    exit 2
  fi
}

print_usage() {
  cat <<'USAGE'
Usage: scripts/update.sh [OPTIONS]

Options:
  --version VERSION  Update to a specific Pi version
  --check            Only check for updates; exits 1 when an update is available
  --help             Show this help message

Examples:
  scripts/update.sh
  scripts/update.sh --check
  scripts/update.sh --version 0.80.3
USAGE
}

parse_arguments() {
  local target_version=""
  local check_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        target_version="${2:-}"
        if [ -z "$target_version" ]; then
          log_error "--version requires a value"
          exit 2
        fi
        shift 2
        ;;
      --check)
        check_only=true
        shift
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        print_usage
        exit 2
        ;;
    esac
  done

  echo "$target_version|$check_only"
}

show_changes() {
  echo ""
  log_info "Changes made:"
  git diff --stat package.nix flake.lock 2>/dev/null || true
}

main() {
  ensure_in_repository_root
  ensure_required_tools_installed

  local args
  args=$(parse_arguments "$@")
  local target_version
  target_version=$(echo "$args" | cut -d'|' -f1)
  local check_only
  check_only=$(echo "$args" | cut -d'|' -f2)

  local current_version
  current_version=$(get_current_version)
  local latest_version
  latest_version="$target_version"
  if [ -z "$latest_version" ]; then
    latest_version=$(get_latest_version)
  fi

  log_info "Current version: $current_version"
  log_info "Latest version: $latest_version"

  if [ "$current_version" = "$latest_version" ]; then
    log_info "Already up to date!"
    exit 0
  fi

  if [ "$check_only" = true ]; then
    log_info "Update available: $current_version → $latest_version"
    exit 1
  fi

  update_to_version "$latest_version"
  show_changes
}

main "$@"
