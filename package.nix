{
  lib,
  buildNpmPackage,
  fetchurl,
  fd,
  makeBinaryWrapper,
  ripgrep,
  stdenvNoCC,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:

buildNpmPackage (finalAttrs: {
  pname = "pi-coding-agent";
  version = "0.84.1";

  # Use the published npm artifact as the packaging boundary. It contains the
  # compiled application, model catalog, and a reproducible npm shrinkwrap.
  src = fetchurl {
    url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${finalAttrs.version}.tgz";
    hash = "sha256-ppoYWWAX6RlV/Q/Wd75p+rW26gHVsGIHvO407hUivCA=";
  };
  sourceRoot = "package";

  # The published shrinkwrap omits integrity fields for monorepo workspace
  # packages. The updater hydrates those fields from npm before committing it.
  postPatch = ''
    cp ${./npm-shrinkwrap.json} npm-shrinkwrap.json

    # The release shrinkwrap intentionally contains production dependencies
    # only, so keep npm ci from resolving unpublished development inputs.
    sed -i '/^[[:space:]]*"devDependencies": {$/,/^[[:space:]]*},$/d' package.json
  '';

  npmDepsHash = "sha256-VtUcBPtmLu6aId/aELsTG+P7w1bzHgw9y6/QJj4HChs=";
  npmFlags = [
    "--ignore-scripts"
    "--no-audit"
    "--no-fund"
  ];
  dontNpmBuild = true;
  dontNpmPrune = true;
  dontPatchShebangs = true;

  nativeBuildInputs = [ makeBinaryWrapper ];

  postInstall = lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
    local nm="$out/lib/node_modules/@earendil-works/pi-coding-agent/node_modules"

    # Remove foreign Linux binaries that make audit-tmpdir inspect ELF RPATHs
    # with patchelf on Darwin.
    rm -rf \
      "$nm/@anthropic-ai/sandbox-runtime/dist/vendor/seccomp" \
      "$nm/@anthropic-ai/sandbox-runtime/vendor/seccomp"
  '';

  postFixup = ''
    local packageOut="$out/lib/node_modules/@earendil-works/pi-coding-agent"
    patchShebangs "$packageOut/dist/cli.js" "$packageOut/dist/rpc-entry.js"

    wrapProgram $out/bin/pi --prefix PATH : ${
      lib.makeBinPath [
        ripgrep
        fd
      ]
    } \
      --set-default PI_SKIP_VERSION_CHECK 1 \
      --set-default PI_TELEMETRY 0
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    versionCheckHook
    writableTmpDirAsHomeHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgram = "${placeholder "out"}/bin/pi";
  versionCheckProgramArg = "--version";

  passthru.updateScript = ./scripts/update.sh;

  meta = {
    description = "Minimal terminal coding harness";
    homepage = "https://pi.dev/";
    downloadPage = "https://www.npmjs.com/package/@earendil-works/pi-coding-agent";
    changelog = "https://github.com/earendil-works/pi/blob/v${finalAttrs.version}/packages/coding-agent/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "pi";
    platforms = lib.platforms.unix;
  };
})
