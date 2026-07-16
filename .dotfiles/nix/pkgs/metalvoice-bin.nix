# pkgs/metalvoice-bin.nix
{
  lib,
  stdenvNoCC,
  fetchzip,
  makeWrapper,
}:

stdenvNoCC.mkDerivation rec {
  pname = "metalvoice-bin";
  version = "1.2";

  src = fetchzip {
    url = "https://github.com/Ghostkwebb/MetalVoice/releases/download/v${version}/MetalVoice_v${version}.zip";

    # First build will fail and print the correct hash.
    # Replace this with the sha256-... it gives you.
    hash = lib.fakeHash;

    stripRoot = false;
  };

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications" "$out/bin"

    app="$(find "$src" -maxdepth 3 -type d -name 'MetalVoice.app' | head -n1)"
    cli="$(find "$src" -maxdepth 3 -type f -name 'MetalVoiceCLI' | head -n1)"

    if [ -z "$app" ]; then
      echo "MetalVoice.app not found in release archive"
      find "$src" -maxdepth 4 -print
      exit 1
    fi

    cp -R "$app" "$out/Applications/MetalVoice.app"

    if [ -n "$cli" ]; then
      cp "$cli" "$out/bin/MetalVoiceCLI"
      chmod +x "$out/bin/MetalVoiceCLI"
    fi

    chmod +x "$out/Applications/MetalVoice.app/Contents/MacOS/MetalVoice"

    # Convenience command: `MetalVoice` opens the GUI app.
    makeWrapper /usr/bin/open "$out/bin/MetalVoice" \
      --add-flags "$out/Applications/MetalVoice.app"

    runHook postInstall
  '';

  meta = {
    description = "AI-powered real-time noise suppression for Apple Silicon macOS";
    homepage = "https://github.com/Ghostkwebb/MetalVoice";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "MetalVoice";
  };
}
