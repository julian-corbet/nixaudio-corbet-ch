{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "nixaudio";
  version = "0.2.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  # These programs deliberately remain unwrapped. On Arch they must talk to the distro's running
  # PipeWire with the distro's pw-dump/wpctl/pw-link/pactl. The service planes provide their PATH;
  # baking a second nixpkgs PipeWire into this package would create the split-brain install the
  # backend module is designed to prevent.
  meta = {
    description = "Semantic PipeWire control plane and StatusNotifier frontend";
    license = pkgs.lib.licenses.mit;
    platforms = pkgs.lib.platforms.linux;
    mainProgram = "nixaudioctl";
  };
}
