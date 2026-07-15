{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  fd,
  makeBinaryWrapper,
  ripgrep,
  stdenvNoCC,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:

buildNpmPackage (finalAttrs: {
  pname = "pi-coding-agent";
  version = "0.80.7";

  src = fetchFromGitHub {
    owner = "earendil-works";
    repo = "pi";
    tag = "v${finalAttrs.version}";
    hash = "sha256-s7dD82fugvWRvqL1VTcEwCIR5JI6t7VeFHR9NdMtG00=";
  };

  npmDepsHash = "sha256-Bd/NIt3lyQR5Y7P+HksPxMQvJc0AjVfDi1M1bH3/eOg=";

  npmWorkspace = "packages/coding-agent";

  # Skip native module rebuild for unneeded workspaces (for example canvas from
  # web-ui). Pi does not require install scripts for normal npm installs.
  npmRebuildFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [ makeBinaryWrapper ];

  # Build workspace dependencies in order, then the coding-agent. We invoke tsgo
  # directly for workspace deps to skip pi-ai's generate-models script, which
  # requires network access. The generated models file is committed upstream.
  buildPhase = ''
    runHook preBuild

    npx tsgo -p packages/ai/tsconfig.build.json
    npx tsgo -p packages/tui/tsconfig.build.json
    npx tsgo -p packages/agent/tsconfig.build.json
    npm run build --workspace=packages/coding-agent

    runHook postBuild
  '';

  # npm workspace symlinks in the output point into packages/, which does not
  # exist there. Replace runtime deps with built content and delete the rest.
  postInstall = ''
    local nm="$out/lib/node_modules/pi-monorepo/node_modules"

    for ws in @earendil-works/pi-ai:packages/ai \
              @earendil-works/pi-agent-core:packages/agent \
              @earendil-works/pi-tui:packages/tui; do
      IFS=: read -r pkg src <<< "$ws"
      rm "$nm/$pkg"
      cp -r "$src" "$nm/$pkg"
    done

    find "$nm" -type l -lname '*/packages/*' -delete
    find "$nm/.bin" -xtype l -delete
  ''
  + lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
    # Remove foreign Linux binaries that make audit-tmpdir try to inspect ELF
    # RPATHs with patchelf on Darwin.
    rm -rf \
      "$nm/@anthropic-ai/sandbox-runtime/dist/vendor/seccomp" \
      "$nm/@anthropic-ai/sandbox-runtime/vendor/seccomp"
  '';

  postFixup = ''
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
    changelog = "https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "pi";
    platforms = lib.platforms.unix;
  };
})
