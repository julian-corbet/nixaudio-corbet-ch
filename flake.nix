{
  description = "Audio as one declared fleet-wide fact: stable device names from the shared USB inventory, and a many-to-many cross-host device pool addressed by name rather than by address.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.system-manager.url = "github:numtide/system-manager";
  inputs.system-manager.inputs.nixpkgs.follows = "nixpkgs";

  # NOTE: nixusb and nixnet are deliberately NOT flake inputs.
  #
  # This module reads `config.nixusb.devices or { }` and `config.nixnet.peers or { }` defensively at
  # eval time — the same idiom nixwatch uses for nixpush, and nixhost for nixnet.interfaces. A host
  # that composes those siblings gets the derived behaviour; a host that does not still evaluates,
  # and simply has to state its devices and peers itself. Taking them as inputs would force every
  # consumer to adopt all three, which is exactly the coupling the family avoids.
  outputs = { self, nixpkgs, system-manager }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      nixosModules.nixaudio = import ./modules/default.nix;
      nixosModules.default = self.nixosModules.nixaudio;

      systemManagerModules.nixaudio = import ./system-manager/default.nix;
      systemManagerModules.default = self.systemManagerModules.nixaudio;

      # The Arch/CachyOS hosts need the USER-session half: PipeWire runs as the logged-in user, its
      # config lives under ~/.config, and the daemon is a `systemd --user` unit. nixarch's package
      # reconciler is pacman convergence only and cannot place files or user units, so this is the
      # mechanism that reaches those two nodes.
      homeManagerModules.nixaudio = import ./home/fabric-sync.nix;
      homeManagerModules.default = self.homeManagerModules.nixaudio;

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit nixpkgs;
          nixaudioModule = self.nixosModules.nixaudio;
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
