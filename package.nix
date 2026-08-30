{ pkgs, craneLib }:
let
  # Only files Cargo consumes belong to the package source. In particular, editing prose or a Nix
  # module must not rebuild the Rust application. Keep all of tests rather than using Crane's
  # default Rust-only filter: the integration harness executes its shell fixtures at runtime.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./Cargo.lock
      ./Cargo.toml
      ./src
      ./tests
    ];
  };

  commonArgs = {
    pname = "nixaudio";
    version = "0.2.0";
    inherit src;

    # Both buildPackage and buildDepsOnly consume this: the former runs the real unit/integration
    # suite, while the latter precompiles its dev dependencies and test targets for reuse.
    doCheck = true;

    # Crane vendors the checked-in Cargo.lock and passes --locked. A dependency update therefore
    # remains an explicit lock-file change, exactly as it was under buildRustPackage.
    strictDeps = true;
  };

  # This derivation is keyed by dependency-relevant Cargo inputs rather than the application
  # sources. Ordinary edits under src/ or tests/ reuse its compiled target directory.
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (commonArgs // {
  inherit cargoArtifacts;

  # tests/daemon.rs starts a real nixaudiod on a private session bus, so the sandbox needs a
  # dbus-daemon. Everything else those tests reach for -- the fake pw-dump, pw-link, wpctl and
  # jacktrip -- is a shell script in tests/fixtures/bin, and `timeout` comes from stdenv.
  nativeCheckInputs = [ pkgs.dbus ];

  # Exposed for the packaging check and for downstream checks that need to share this exact
  # dependency build rather than compiling a second target directory.
  passthru = { inherit cargoArtifacts; };

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
})
