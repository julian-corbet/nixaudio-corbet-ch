{
  description = "Audio as one declared fleet-wide fact: stable device names from the shared USB inventory, and a many-to-many cross-host device pool addressed by name rather than by address.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.system-manager.url = "github:numtide/system-manager";
  inputs.system-manager.inputs.nixpkgs.follows = "nixpkgs";

  # nixusb is deliberately not a flake input.
  #
  # A host that composes nixusb gets stable USB identity from its shared inventory. Peer membership
  # is always explicit nixaudio data: an audio circle must not silently grow whenever a generic
  # network peer appears, and no overlay product is part of the transport contract.
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

      # The Home Manager plane owns user-session config and units. A foreign host hub supplies its
      # package and command-path backend in the same evaluation.
      homeManagerModules.nixaudio = import ./home/default.nix;
      homeManagerModules.default = self.homeManagerModules.nixaudio;

      # NixOS resolution is exposed as a pure helper over the package set this flake already owns.
      # There is deliberately no Arch package table here: nixarch resolves the same `nixaudio.want`
      # contract without becoming an input of this flake (the family contract's R4 boundary).
      lib.nixosRoles = pkgs: import ./lib/nixos-roles.nix { inherit lib pkgs; };

      # The two diagnostics, runnable without composing anything. Both are ordinarily wired into a
      # unit or a scheduler by a plane, but the whole point of a health probe is that a human can
      # ask the question directly when something is wrong -- `nix run .#alsa-guard` answers "does
      # this session have its cards" on any host, including one that has never heard of this flake.
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          moduleEval = lib.evalModules {
            specialArgs = { inherit pkgs; };
            modules = [
              ./modules/guard.nix
              ./modules/monitor.nix
              ./modules/devices.nix
              ./modules/dropins.nix
              ./modules/fabric.nix
              ./modules/catalogue.nix
              ./modules/daemon.nix
              { options.environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; }; }
              { options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; }; }
              { options.warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; }; }
            ];
          };
        in
        {
          nixaudio = import ./package.nix { inherit pkgs; };
          jacktrip = import ./jacktrip-package.nix { inherit pkgs; };
          alsa-guard = moduleEval.config.nixaudio.guard.package;
          fabric-health = moduleEval.config.nixaudio.fabric.healthCheck;
          default = self.packages.${system}.nixaudio;
        });

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit nixpkgs;
          nixaudioModule = self.nixosModules.nixaudio;
          archModule = self.systemManagerModules.nixaudio;
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
