{ pkgs }:

# A source-pinned build of the upstream JackTrip CLI/JACK engine. This is packaging, not a fork:
# no upstream source is patched or vendored. The full nixpkgs package enables JackTrip's QML GUI and
# Virtual Studio and consequently wraps a WebEngine closure; nixaudio already supplies the product
# UI and needs only the media process.
pkgs.stdenv.mkDerivation {
  pname = "jacktrip-headless";
  version = "3.0.0";

  src = pkgs.fetchFromGitHub {
    owner = "jacktrip";
    repo = "jacktrip";
    tag = "v3.0.0";
    fetchSubmodules = true;
    hash = "sha256-f9GLH5WXhdsLnZ8jDVtPNgGOAaoFnUUDeYaiAJP8bOQ=";
  };

  preConfigure = "rm build";

  nativeBuildInputs = [
    pkgs.pkg-config
    pkgs.meson
    pkgs.ninja
    pkgs.help2man
    pkgs.qt6.qtbase
    (pkgs.python3.withPackages (python: [ python.pyaml python.jinja2 ]))
    pkgs.versionCheckHook
  ];

  buildInputs = [
    pkgs.libjack2
    pkgs.libsamplerate
    pkgs.qt6.qtbase
  ];
  dontWrapQtApps = true;

  mesonFlags = [
    "-Dnogui=true"
    "-Dnovs=true"
    "-Drtaudio=disabled"
    "-Djack=enabled"
  ];

  doInstallCheck = true;
  versionCheckProgramArg = "--version";

  meta = {
    description = "Headless upstream JackTrip real-time audio transport";
    homepage = "https://jacktrip.github.io/jacktrip/";
    changelog = "https://github.com/jacktrip/jacktrip/releases/tag/v3.0.0";
    license = with pkgs.lib.licenses; [ gpl3 lgpl3 mit ];
    platforms = pkgs.lib.platforms.linux;
    mainProgram = "jacktrip";
  };
}
