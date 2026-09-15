# pi-nix

Always-fresh Nix package for [Pi](https://pi.dev), the minimal terminal coding harness.

This mirrors the shape of `sadjow/claude-code-nix` and `sadjow/codex-cli-nix`: the flake packages upstream Pi, checks npm for new versions on a schedule, updates hashes automatically, builds/tests the result, and opens an update PR.

## Why

`nixpkgs` already packages Pi, but it can lag upstream npm. This repository is a small dedicated flake for people who want Pi releases shortly after they are published to npm.

As of 2026-07-09, `@earendil-works/pi-coding-agent` had published 27 versions since 2026-05-07, with 13 releases in the previous 30 days. So hourly checks are not strictly necessary, but they are cheap and match the Claude/Codex setup.

## Usage

Run directly:

```bash
nix run github:MattiasMTS/pi-nix
```

Install to a profile:

```bash
nix profile install github:MattiasMTS/pi-nix
```

Use from another flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    pi-nix = {
      url = "github:MattiasMTS/pi-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

Then add it to Home Manager:

```nix
home.packages = [
  inputs.pi-nix.packages.${pkgs.system}.pi-coding-agent
];
```

## Development

Build and test locally:

```bash
nix build .#pi-coding-agent
./result/bin/pi --version
```

Check for updates:

```bash
./scripts/update.sh --check
```

Update to latest:

```bash
./scripts/update.sh
```

Update to a specific version:

```bash
./scripts/update.sh --version 0.84.1
```

## Automation

GitHub Actions included here:

- `Build`: builds and smoke-tests Pi on Linux and macOS.
- `Update Pi Version`: checks npm hourly, updates `package.nix` and the hydrated npm shrinkwrap, and maintains one PR on the `update-pi` branch. It explicitly starts and waits for the Linux/macOS builds, merges the tested commit, and starts a build on `main` for tagging. Failed updates stay open and are retried on the next scheduled run.
- `Create Version Tag`: creates immutable `vX.Y.Z` tags plus moving `latest` and `vMAJOR` tags after successful main builds.

Keep the `build (ubuntu-latest)` and `build (macos-latest)` checks required in the rules for `main`. Updates use the repository's `GITHUB_TOKEN` with `actions: write`, `contents: write`, and `pull-requests: write`; no PAT, GitHub App, or manual workflow approval is needed. Allow GitHub Actions to create pull requests in the repository's Actions settings.

Run the automation tests locally with `python3 -m unittest discover -s tests -v`.

## Notes

This package installs Pi from the published `@earendil-works/pi-coding-agent` tarball and realizes its production dependency tree reproducibly through `buildNpmPackage`. Using the release artifact avoids duplicating the upstream monorepo build graph. It also wraps `pi` with `ripgrep` and `fd` in `PATH`, and sets:

- `PI_SKIP_VERSION_CHECK=1` because Nix owns the binary version.
- `PI_TELEMETRY=0` to avoid install/update telemetry from this Nix-managed build.
