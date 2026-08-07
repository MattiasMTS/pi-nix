#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

readonly NPM_REGISTRY_URL="https://registry.npmjs.org"
readonly NPM_PACKAGE_NAME="@earendil-works/pi-coding-agent"
readonly NPM_TARBALL_NAME="pi-coding-agent"
readonly FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

get_current_version() {
	sed -n 's/.*version = "\([^"]*\)".*/\1/p' package.nix | head -1
}

fetch_npm_version() {
	npm view "$NPM_PACKAGE_NAME" version 2>/dev/null
}

get_latest_version() {
	local version
	version=$(fetch_npm_version || true)
	if [ -z "$version" ]; then
		log_error "Failed to fetch latest version for $NPM_PACKAGE_NAME"
		exit 2
	fi
	printf '%s\n' "$version"
}

set_version() {
	local version="$1"
	local temp_file
	temp_file=$(mktemp)
	sed -E "s/version = \"[^\"]+\"/version = \"$version\"/" package.nix >"$temp_file"
	mv "$temp_file" package.nix
}

set_source_hash() {
	local hash="$1"
	local temp_file
	temp_file=$(mktemp)

	awk -v hash="$hash" '
    /src = fetchurl \{/ { in_src=1 }
    in_src && /hash = / {
      sub(/hash = "[^"]+"/, "hash = \"" hash "\"")
      in_src=0
    }
    { print }
  ' package.nix >"$temp_file"
	mv "$temp_file" package.nix
}

set_npm_deps_hash() {
	local hash="$1"
	local temp_file
	temp_file=$(mktemp)
	sed -E "s|npmDepsHash = \"[^\"]+\"|npmDepsHash = \"$hash\"|" package.nix >"$temp_file"
	mv "$temp_file" package.nix
}

npm_tarball_url() {
	local version="$1"
	printf '%s/%s/-/%s-%s.tgz\n' \
		"$NPM_REGISTRY_URL" "$NPM_PACKAGE_NAME" "$NPM_TARBALL_NAME" "$version"
}

prefetch_source() {
	local version="$1"
	nix store prefetch-file --json "$(npm_tarball_url "$version")" 2>/dev/null
}

hydrate_npm_shrinkwrap() {
	local source_path="$1"
	local temp_dir
	temp_dir=$(mktemp -d)
	tar -xzf "$source_path" -C "$temp_dir" package/npm-shrinkwrap.json

	local lock_file="$temp_dir/package/npm-shrinkwrap.json"
	while IFS=$'\t' read -r key version; do
		local package="${key##*node_modules/}"
		local integrity
		integrity=$(npm view "$package@$version" dist.integrity 2>/dev/null)
		if [ -z "$integrity" ]; then
			log_error "Failed to fetch npm integrity for $package@$version"
			rm -rf "$temp_dir"
			return 1
		fi

		local next_lock="$lock_file.next"
		jq --tab --arg key "$key" --arg integrity "$integrity" \
			'.packages[$key].integrity = $integrity' "$lock_file" >"$next_lock"
		mv "$next_lock" "$lock_file"
	done < <(
		jq -r '
      .packages | to_entries[]
      | select(.key != "")
      | select(.value.link != true)
      | select((.value.resolved // "") | startswith("git+") | not)
      | select(.value.integrity == null)
      | [.key, .value.version]
      | @tsv
    ' "$lock_file"
	)

	local missing_integrities
	missing_integrities=$(
		jq '
      [
        .packages | to_entries[]
        | select(.key != "")
        | select(.value.link != true)
        | select((.value.resolved // "") | startswith("git+") | not)
        | select(.value.integrity == null)
      ] | length
    ' "$lock_file"
	)
	if [ "$missing_integrities" -ne 0 ]; then
		log_error "Hydrated shrinkwrap still has $missing_integrities missing integrity fields"
		rm -rf "$temp_dir"
		return 1
	fi

	cp "$lock_file" npm-shrinkwrap.json
	rm -rf "$temp_dir"
}

extract_got_hash() {
	sed -nE 's/^[[:space:]]*got:[[:space:]]+(sha256-[A-Za-z0-9+\/=]+).*/\1/p' | tail -1
}

prefetch_npm_deps_hash() {
	local output
	local status

	set +e
	output=$(nix build .#pi-coding-agent --no-link 2>&1)
	status=$?
	set -e

	if [ "$status" -eq 0 ]; then
		log_error "Expected an npmDepsHash mismatch, but nix build succeeded"
		return 1
	fi

	local hash
	hash=$(printf '%s\n' "$output" | extract_got_hash)
	if [ -z "$hash" ]; then
		log_error "Could not extract npmDepsHash from nix output:"
		printf '%s\n' "$output" >&2
		return 1
	fi

	printf '%s\n' "$hash"
}

rollback_package() {
	local backup_dir="$1"
	cp "$backup_dir/package.nix" package.nix
	cp "$backup_dir/npm-shrinkwrap.json" npm-shrinkwrap.json
	rm -rf "$backup_dir"
}

update_to_version() {
	local new_version="$1"
	local backup_dir
	backup_dir=$(mktemp -d)
	cp package.nix npm-shrinkwrap.json "$backup_dir"
	trap 'rollback_package "$backup_dir"' ERR
	trap 'rollback_package "$backup_dir"; exit 130' INT
	trap 'rollback_package "$backup_dir"; exit 143' TERM

	log_info "Updating pi-coding-agent to version $new_version..."
	set_version "$new_version"

	log_info "Prefetching npm release tarball..."
	local source_info
	source_info=$(prefetch_source "$new_version")
	local source_hash
	source_hash=$(jq -r .hash <<<"$source_info")
	local source_path
	source_path=$(jq -r .storePath <<<"$source_info")
	if [ -z "$source_hash" ] || [ -z "$source_path" ]; then
		log_error "Failed to prefetch npm release tarball for $new_version"
		return 1
	fi
	log_info "  source: $source_hash"
	set_source_hash "$source_hash"

	log_info "Hydrating npm shrinkwrap integrity fields..."
	hydrate_npm_shrinkwrap "$source_path"

	log_info "Prefetching npm dependencies..."
	set_npm_deps_hash "$FAKE_HASH"
	local npm_hash
	npm_hash=$(prefetch_npm_deps_hash)
	log_info "  npmDepsHash: $npm_hash"
	set_npm_deps_hash "$npm_hash"

	if command -v nixfmt >/dev/null 2>&1; then
		nixfmt package.nix || true
	elif command -v nixfmt-rfc-style >/dev/null 2>&1; then
		nixfmt-rfc-style package.nix || true
	fi

	log_info "Verifying build..."
	local output_path
	output_path=$(nix build .#pi-coding-agent --no-link --print-out-paths --print-build-logs)
	"$output_path/bin/pi" --version

	rm -rf "$backup_dir"
	trap - ERR INT TERM
	log_info "Successfully updated pi-coding-agent to $new_version"
}

ensure_in_repository_root() {
	if [ ! -f flake.nix ] || [ ! -f package.nix ]; then
		log_error "flake.nix or package.nix not found. Run this script from the repository root."
		exit 2
	fi
}

ensure_required_tools_installed() {
	for tool in nix npm jq tar; do
		command -v "$tool" >/dev/null 2>&1 || {
			log_error "$tool is required but not installed."
			exit 2
		}
	done
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
  scripts/update.sh --version 0.84.1
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

	printf '%s|%s\n' "$target_version" "$check_only"
}

main() {
	ensure_in_repository_root
	ensure_required_tools_installed

	local args
	args=$(parse_arguments "$@")
	local target_version="${args%%|*}"
	local check_only="${args#*|}"
	local current_version
	current_version=$(get_current_version)
	local latest_version="$target_version"

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
	git diff --stat package.nix npm-shrinkwrap.json 2>/dev/null || true
}

main "$@"
