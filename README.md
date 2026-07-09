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
./scripts/update.sh --version 0.80.3
```

## Automation

GitHub Actions included here:

- `Build`: builds and smoke-tests Pi on Linux and macOS.
- `Update Pi Version`: checks npm hourly, updates `package.nix` + `flake.lock`, and opens an auto-merge PR.
- `Create Version Tag`: creates immutable `vX.Y.Z` tags plus moving `latest` and `vMAJOR` tags after successful main builds.

For auto-merge to work, enable GitHub repository auto-merge and use branch protection that requires the `Build` check.

## Notes

This package builds Pi from the upstream `earendil-works/pi` source tag and bundles the npm dependency tree through `buildNpmPackage`. It also wraps `pi` with `ripgrep` and `fd` in `PATH`, and sets:

- `PI_SKIP_VERSION_CHECK=1` because Nix owns the binary version.
- `PI_TELEMETRY=0` to avoid install/update telemetry from this Nix-managed build.
