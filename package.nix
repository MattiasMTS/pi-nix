{
  lib,
  autoPatchelfHook,
  fd,
  importNpmLock,
  libxcb,
  makeBinaryWrapper,
  nodejs_22,
  ripgrep,
  stdenv,
  versionCheckHook,
  wl-clipboard,
  writableTmpDirAsHomeHook,
  xclip,
}:

let
  # install-lock/ is the lockfile the official pi.dev installer uses for
  # managed installs, synced by scripts/update.sh. Building from it gives the
  # same node_modules tree a `curl pi.dev/install.sh | sh` user gets.
  lockRoot = ./install-lock;
  version = (lib.importJSON (lockRoot + "/package.json")).version;
  nodejs = nodejs_22;
  pkgDir = "$out/lib/pi/node_modules/@earendil-works/pi-coding-agent";
in
stdenv.mkDerivation {
  pname = "pi-coding-agent";
  inherit version;
  src = lockRoot;

  npmDeps = importNpmLock { npmRoot = lockRoot; };
  # Mirrors the installer: npm ci --ignore-scripts --omit=dev --include=optional
  npmInstallFlags = [
    "--omit=dev"
    "--include=optional"
  ];
  npmRebuildFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [
    nodejs
    importNpmLock.npmConfigHook
    makeBinaryWrapper
  ]
  # pi-tui ships prebuilt native clipboard helpers; same treatment as upstream's flake.
  ++ lib.optional stdenv.hostPlatform.isLinux autoPatchelfHook;

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
    libxcb
  ];

  dontBuild = true;
  dontPatchShebangs = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/pi
    cp -R package.json package-lock.json node_modules $out/lib/pi/
    makeWrapper ${nodejs}/bin/node $out/bin/pi \
      --add-flags ${pkgDir}/dist/bundle/cli.js \
      --prefix PATH : ${
        lib.makeBinPath (
          [
            nodejs
            ripgrep
            fd
          ]
          ++ lib.optionals stdenv.hostPlatform.isLinux [
            wl-clipboard
            xclip
          ]
        )
      } \
      --set-default PI_SKIP_VERSION_CHECK 1 \
      --set-default PI_TELEMETRY 0

    runHook postInstall
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
    changelog = "https://github.com/earendil-works/pi/blob/v${version}/packages/coding-agent/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "pi";
    platforms = lib.platforms.unix;
  };
}
