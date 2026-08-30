{ pkgs, nixpkgs, nixaudioModule, archModule }:
let
  lib = nixpkgs.lib;

  nixusbStub = { lib, ... }: {
    options.nixusb.devices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          vendorId = lib.mkOption { type = lib.types.str; };
          productId = lib.mkOption { type = lib.types.str; };
          serial = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          description = lib.mkOption { type = lib.types.str; default = ""; };
          tags = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
        };
      });
      default = { };
    };
  };

  commonStub = { lib, ... }: {
    options = {
      assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      services.pipewire = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      environment.etc = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      hardware.firmware = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      systemd.user.timers = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      users.users = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      security.pam.loginLimits = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
    };
  };

  circle = {
    nixaudio.fabric = {
      enable = true;
      node = "alpha";
      control.listen = "192.0.2.1";
      peers.beta = {
        addresses = [ "192.0.2.2" "beta.example.net" ];
        audioPort = 26301;
      };
    };
  };

  evalNixos = extra: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      nixaudioModule
      commonStub
      {
        nixaudio.daemon.user = "audio-test";
        nixaudio.rt = {
          enable = true;
          group = "studio-audio";
          memlock = "unlimited";
        };
      }
      circle
    ] ++ extra;
  };
  evalNixosBare = extra: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [ nixaudioModule commonStub ] ++ extra;
  };
  evalArch = extra: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      archModule
      commonStub
      {
        nixaudio.rt = {
          enable = true;
          group = "studio-audio";
          memlock = "unlimited";
        };
      }
      circle
    ] ++ extra;
  };

  homeStub = { lib, ... }: {
    options = {
      xdg.configHome = lib.mkOption { type = lib.types.str; default = "/home/test/.config"; };
      xdg.configFile = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      systemd.user.timers = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };
  evalHome = extra: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [ ../home/default.nix homeStub circle ] ++ extra;
  };

  nixos = evalNixos [
    nixusbStub
    {
      nixusb.devices.headset = {
        vendorId = "1234";
        productId = "abcd";
        serial = "TEST-SERIAL-0001";
        description = "Test headset";
        tags = [ "audio" ];
      };
    }
  ];
  arch = evalArch [ ];
  home = evalHome [ ];
  failed = value: builtins.filter (assertion: !assertion.assertion) value.config.assertions;
  check = name: condition:
    assert condition;
    pkgs.runCommand "nixaudio-${name}" { } "touch $out";
in
{
  rust = import ../package.nix { inherit pkgs; };
  jacktrip = import ../jacktrip-package.nix { inherit pkgs; };

  architecture = check "architecture" (
    nixos.config.nixaudio.daemon.settings.node == "alpha"
    && nixos.config.nixaudio.daemon.settings.control.listen == "192.0.2.1"
    && nixos.config.nixaudio.daemon.settings.control.port == 26300
    && nixos.config.nixaudio.daemon.settings.peers.beta.addresses
    == [ "192.0.2.2" "beta.example.net" ]
    && nixos.config.nixaudio.daemon.settings.peers.beta.controlPort == 26300
    && nixos.config.nixaudio.daemon.settings.peers.beta.audioPort == 26301
    && nixos.config.nixaudio.daemon.settings.transport.command
    == [
      "${pkgs.pipewire.jack}/bin/pw-jack"
      "${nixos.config.nixaudio.fabric.transport.package}/bin/jacktrip"
    ]
  );

  # NixOS renders `path` as an exclusive Environment=PATH, so anything the daemon shells out to and
  # cannot find is a dead D-Bus method rather than a build error. The daemon runs `timeout` and
  # `pw-dump`/`pw-link` (graph.rs:207,727,763,796) and `wpctl` (graph.rs:842,858,871) -- and wpctl
  # ships in wireplumber, not pipewire, which is exactly the kind of split a unit test cannot see.
  daemon-tooling = check "daemon-tooling" (
    let
      path = nixos.config.systemd.user.services.nixaudiod.path;
    in
    builtins.elem pkgs.coreutils path
    && builtins.elem pkgs.pipewire path
    && builtins.elem pkgs.wireplumber path
  );

  # The guard's repair budget is a safety boundary, not optional tooling. Its state-window filter
  # calls awk; omitting gawk from NixOS's exclusive service PATH used to truncate the attempts file
  # on every run and turn a bounded three-restart repair into an unbounded WirePlumber restart loop.
  guard-tooling = check "guard-tooling" (
    let
      path = nixos.config.systemd.user.services.nixaudio-alsa-guard.path;
    in
    builtins.elem pkgs.pipewire path
    && builtins.elem pkgs.jq path
    && builtins.elem pkgs.gawk path
    && builtins.elem pkgs.systemd path
  );

  pipewire-boundary = check "pipewire-boundary" (
    nixos.config.services.pipewire.jack.enable
    && !(nixos.config.services.pipewire ? extraConfig)
    && builtins.elem "pipewire-jack" arch.config.nixaudio.backend.archPackages
    && !(builtins.elem "pipewire-zeroconf" arch.config.nixaudio.backend.archPackages)
  );

  live-discovery = check "live-discovery" (
    builtins.attrNames nixos.config.nixaudio.fabric.catalogue == [ "headset" ]
    && nixos.config.nixaudio.fabric.catalogue.headset.origin == "local"
    && !(nixos.config.nixaudio.fabric.catalogue ? "beta.headset")
  );

  realtime-projection = check "realtime-projection" (
    builtins.elem "audio" nixos.config.users.users.audio-test.extraGroups
    && builtins.elem "studio-audio" nixos.config.users.users.audio-test.extraGroups
    && nixos.config.security.pam.loginLimits == [
      { domain = "@studio-audio"; type = "-"; item = "rtprio"; value = "95"; }
      { domain = "@studio-audio"; type = "-"; item = "nice"; value = "-11"; }
      { domain = "@studio-audio"; type = "-"; item = "memlock"; value = "unlimited"; }
    ]
    && arch.config.environment.etc."security/limits.d/50-nixaudio.conf".text
    == arch.config.nixaudio.rt.limitsConfig
  );

  user-unit-safety = check "user-unit-safety" (
    nixos.config.nixaudio.guard.user == "audio-test"
    && nixos.config.systemd.user.services.nixaudiod.unitConfig.ConditionUser == "audio-test"
    && nixos.config.systemd.user.services.nixaudio-alsa-guard.unitConfig.ConditionUser == "audio-test"
  );

  arch-plane = check "arch-plane" (
    arch.config.nixaudio.fabric.transport.command
    == [
      "${pkgs.pipewire.jack}/bin/pw-jack"
      "${arch.config.nixaudio.fabric.transport.package}/bin/jacktrip"
    ]
    && arch.config.environment.etc ? "nixaudio/config.json"
    && arch.config.environment.etc ? "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf"
    && !(arch.config.environment.etc ? "pipewire/pipewire.conf.d/50-nixaudio-fabric-loops.conf")
    && !(arch.config.environment.etc ? "pipewire/pipewire-pulse.conf.d/50-nixaudio-fabric-listener.conf")
  );

  home-plane = check "home-plane" (
    home.config.nixaudio.fabric.transport.command
    == [
      "${pkgs.pipewire.jack}/bin/pw-jack"
      "${home.config.nixaudio.fabric.transport.package}/bin/jacktrip"
    ]
    && home.config.xdg.configFile ? "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf"
    && !(home.config.xdg.configFile ? "pipewire/pipewire.conf.d/50-nixaudio-fabric-loops.conf")
    && !(home.config.xdg.configFile ? "pipewire/pipewire-pulse.conf.d/50-nixaudio-fabric-listener.conf")
  );

  assertions = check "assertions" (
    failed nixos == [ ]
    && failed arch == [ ]
    && failed home == [ ]
    && failed (evalNixos [{ nixaudio.fabric.transport.queue = "auto250"; }]) == [ ]
    && failed (evalNixos [{ nixaudio.fabric.transport.queue = "auto251"; }]) != [ ]
    && failed (evalNixos [{ nixaudio.fabric.transport.queue = "4"; }]) != [ ]
    && failed (evalNixos [{ nixaudio.daemon.enable = false; }]) != [ ]
    && failed (evalNixosBare [{ nixaudio.backend.enable = true; }]) != [ ]
    && failed (evalNixosBare [{ nixaudio.tray.enable = true; }]) != [ ]
    && failed
      (evalNixos [{
        nixaudio.fabric.peers.alpha = {
          addresses = [ "127.0.0.1" ];
          audioPort = 26302;
        };
      }]) != [ ]
    && failed
      (evalNixos [{
        nixaudio.fabric.peers.gamma = {
          addresses = [ "192.0.2.3" ];
          audioPort = 26301;
        };
      }]) != [ ]
  );
}
