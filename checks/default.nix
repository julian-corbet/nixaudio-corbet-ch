# Pure evaluation checks. Everything nixaudio produces is a pure function of declared data, so the
# whole contract is verifiable without a VM or a host. Both directions are proven throughout: the
# right output is generated, AND the inputs that must be rejected are.
{ pkgs, nixpkgs, nixaudioModule, archModule }:
let
  lib = nixpkgs.lib;

  # The backend table and its resolution, imported directly. The table is what the module actually
  # uses, so a check reading it here cannot drift from what a host gets; the resolution functions
  # are exercised against FIXTURES below, for the branches no live entry has (`arch = null`,
  # `aur = true`) -- see ../lib/resolve.nix's own header.
  backendTable = import ../lib/packages.nix { };
  resolve = import ../lib/resolve.nix { inherit lib; };

  # nixusb's option surface, inlined as a stub. nixaudio reads `config.nixusb.devices or { }`
  # defensively, so the checks must be able to exercise BOTH the composed case (this stub present)
  # and the absent case -- which is the whole point of the defensive read.
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

  nixnetStub = { lib, ... }: {
    options.nixnet.peers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.hostnames = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      });
      default = { };
    };
  };

  # nixwatch remains a soft dependency. This is only the check submodule shape nixaudio fills;
  # channel is intentionally supplied by the consumer because delivery policy is not audio policy.
  nixwatchStub = { lib, ... }: {
    options.nixwatch.checks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          probe = lib.mkOption { type = lib.types.str; };
          interval = lib.mkOption { type = lib.types.str; };
          deadline = lib.mkOption { type = lib.types.str; };
          severity = lib.mkOption { type = lib.types.str; };
          channel = lib.mkOption { type = lib.types.str; };
        };
      });
      default = { };
    };
  };

  # The daemon and monitor modules take `pkgs`, so it has to be threaded through as a specialArg --
  # these are the same real pkgs the flake check runs with, so the packaged daemon and health probe
  # are evaluated for real rather than against a stub that could hide a broken derivation.
  #
  # The stub set is shared by BOTH plane roots (the NixOS module and the system-manager one) so that
  # the two are evaluated against identical surroundings and any difference between them is the
  # planes' own, not the fixtures'.
  evalPlane = root: modules: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      root
      { options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; }; }
      { options.warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; }; }
      { options.services.pipewire = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; }; }
      { options.environment.etc = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; }; }
      { options.environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; }; }
      { options.hardware.firmware = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; }; }
      { options.systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; }; }
      { options.systemd.user.timers = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; }; }
      { options.users.users = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; }; }
      { options.security.pam.loginLimits = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; }; }
    ] ++ modules;
  };

  # A NixOS fabric daemon has to name its user. Keep that ordinary valid default in all the broad
  # fixtures, and exercise the rejected missing-user shape separately below.
  eval = modules: evalPlane nixaudioModule ([
    { nixaudio.fabric.daemon.user = lib.mkDefault "test-user"; }
  ] ++ modules);
  evalWithoutDaemonUser = evalPlane nixaudioModule;

  # The Arch/system-manager plane, evaluated for real rather than assumed to mirror the NixOS one.
  # It is the plane where the backend is PACKAGES rather than options, so "the same selection
  # resolves on both planes" is a claim that has to be checked, not asserted.
  evalArch = evalPlane archModule;

  # nixiam.posix's group registry, stubbed. Only the shape nixaudio.rt reads is needed.
  nixiamStub = { lib, ... }: {
    options.nixiam.posix.deviceGroups = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = { };
    };
    options.nixiam.posix.groups = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = { };
    };
  };

  # home-manager's option surface, stubbed, so the home plane can be evaluated without pulling
  # home-manager in as a flake input just to test it.
  homeStub = { lib, ... }: {
    options.xdg.configHome = lib.mkOption { type = lib.types.str; default = "/home/test/.config"; };
    options.xdg.configFile = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
    options.systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
    options.systemd.user.timers = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
    options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
    options.warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
  };

  evalHome = modules: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [ ../home/fabric-sync.nix homeStub ] ++ modules;
  };

  failed = c: builtins.filter (a: !a.assertion) c.config.assertions;

  inventory = {
    nixusb.devices = {
      hyperx = { vendorId = "03f0"; productId = "06be"; serial = "C1V51706C2"; tags = [ "audio" ]; };
      shure = { vendorId = "14ed"; productId = "1010"; tags = [ "audio" ]; };
      dock = { vendorId = "17e9"; productId = "6000"; serial = "GWCD00161000515"; tags = [ "video" ]; };
    };
  };

  composed = eval [
    nixusbStub
    nixnetStub
    inventory
    {
      nixnet.peers.host-a.hostnames = [ "host-a" "host-a.example.com" ];
      nixnet.peers.host-b.hostnames = [ "host-b" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
    }
  ];

  # nixusb and nixnet BOTH absent -- the defensive-read path.
  standalone = eval [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.6";
      nixaudio.fabric.peers.other.host = "host-c";
      nixaudio.devices.internal.match."device.name" =
        "alsa_card.pci-0000_00_1f.3-platform-skl_hda_dsp_generic";
    }
  ];

  noPeers = eval [
    nixusbStub
    nixnetStub
    { nixaudio.fabric.enable = true; nixaudio.fabric.listen.address = "203.0.113.14"; }
  ];

  # nixnet declares host-b as a peer key, but has published no hostnames for it -- the one flavour of
  # "missing peer" nixaudio can actually see (see modules/fabric.nix's droppedPeers). host-a is a
  # normal, fully-published peer in the SAME fixture, so this also proves the drop is scoped to the
  # one incomplete entry rather than nuking the whole peer set.
  partialPeers = eval [
    nixusbStub
    nixnetStub
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixnet.peers.host-b.hostnames = [ ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
    }
  ];

  collision = eval [
    nixusbStub
    inventory
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      # Redeclaring a device nixusb already provides -- the "two inventories" mistake.
      nixaudio.devices.hyperx.match."device.vendor.id" = "0x03f0";
    }
  ];

  # Same fixture shape as `composed`, plus explicit sink/source priority overrides -- proves the
  # exact tie the live defect describes (HyperX and Shure both carrying WirePlumber's own
  # priority.session = 1109 for their sinks) is something this option can actually break.
  withPriority = eval [
    nixusbStub
    nixnetStub
    inventory
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      # hyperx: both axes overridden, to DIFFERENT values -- proves sink and source are rendered
      # independently rather than one option secretly driving both.
      nixaudio.priorities.hyperx = { sink = 2000; source = 1500; };
      # shure: only source overridden -- proves declaring one axis does not also emit a rule (with
      # some default value) for the axis left alone.
      nixaudio.priorities.shure.source = 2200;
    }
  ];

  # A priority aimed at ONE node of a card that spawns several. Without the narrowing key, an
  # internal codec's speakers, and every HDMI output on the same card, all receive one number --
  # measured live as four sinks collapsing from 1000/696/680/664 into a single value.
  profiledPriority = eval [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers.other.host = "host-c";
      nixaudio.devices.builtin.match."device.vendor.id" = "0x8086";
      nixaudio.priorities.builtin.sink = { priority = 1450; profile = "HiFi: Speaker: sink"; };
    }
  ];

  # A host that wants declared priority to outrank a remembered `wpctl set-default`.
  noRestore = eval [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers.other.host = "host-c";
      nixaudio.restoreDefaultTargets = false;
      nixaudio.devices.internal.match."device.name" = "alsa_card.internal";
    }
  ];

  # ── Guard fixtures ──────────────────────────────────────────────────────────────────────────
  guarded = eval [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers.other.host = "host-c";
      nixaudio.guard.user = "alice";
    }
  ];

  # No fabric at all -- the guard must still be there, because losing the ALSA enumeration has
  # nothing to do with whether this host joins a device pool.
  backendOnlyGuard = eval [{ nixaudio.backend.enable = true; }];

  guardOff = eval [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers.other.host = "host-c";
      nixaudio.guard.enable = false;
    }
  ];

  guardNoTimer = eval [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers.other.host = "host-c";
      nixaudio.guard.interval = null;
    }
  ];

  # A host that genuinely shares its cards with another sound server and must keep the handshake.
  reserveOn = eval [{ nixaudio.backend.enable = true; nixaudio.guard.reserveDevice = true; }];

  # ── dropIns fixtures: the two-planes-one-host case ──────────────────────────────────────────
  homeSystemDropIns = evalHome [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers.host-a.host = "host-a";
      nixaudio.dropIns = "system";
    }
  ];

  # The normal two-plane Arch shape after system-manager became the single owner of the generated
  # config. Home Manager knows no listener or peers at all; it only points the service at /etc.
  homeExternalDaemon = evalHome [
    {
      nixaudio.fabric.daemon.enable = true;
      nixaudio.fabric.daemon.externalConfigPath = "/etc/nixaudio/fabric.json";
      nixaudio.dropIns = "system";
    }
  ];

  archUserDropIns = evalArch [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers.host-a.host = "host-a";
      nixaudio.dropIns = "user";
    }
  ];

  # A priority declared for a device name nothing on this host resolves to -- the "typo, or the
  # device was never actually composed" mistake `unknownPriorityNames` exists to catch.
  unknownPriority = eval [
    nixusbStub
    nixnetStub
    inventory
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.priorities.bogus.sink = 100;
    }
  ];

  # A second composed host, alongside `composed` above, that ALSO carries an explicitly-declared
  # (non-USB) device. `composed` itself is asserted elsewhere to resolve to exactly
  # `[ "hyperx" "shure" ]`, so the explicit-device case gets its own fixture rather than perturbing
  # a fixture several other checks already depend on.
  composedWithExplicit = eval [
    nixusbStub
    nixnetStub
    inventory
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.devices.internal-codec.match."device.name" = "alsa_card.pci-internal";
    }
  ];

  # Three peers rather than composed's two -- proves the catalogue's peer tier actually SCALES with
  # nixaudio.fabric.peers instead of happening to be correct for one particular count.
  manyPeers = eval [
    nixusbStub
    nixnetStub
    inventory
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixnet.peers.host-b.hostnames = [ "host-b" ];
      nixnet.peers.host-c.hostnames = [ "host-c" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
    }
  ];

  # A local device deliberately named to COLLIDE with a "<peer>.<device>" key the catalogue would
  # otherwise generate for this same fleet -- proves the collision guard actually fires instead of
  # silently letting one entry clobber the other via `//`.
  catalogueCollision = eval [
    nixusbStub
    nixnetStub
    inventory
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.devices."host-a.hyperx".match."device.name" = "bogus";
    }
  ];

  # THE BUG THIS DEFENSE IS FOR: nixnet derives TWO peers, but the fixture pins ONE of them via a
  # NESTED, dotted-path definition (`peers.host-a.host = ...`) instead of the whole `peers = {...}`
  # attrset -- the exact shape that collapsed one fleet host's audio peers to a single hand-written
  # entry with no error. `cfg.peers` itself is UNCHANGED by the new defense (that would require
  # rewriting the option's merge semantics, which would break the legitimate "explicit peers is a
  # deliberate strict subset" case -- see `homePlane`, above, and the `peers` option's own
  # description); what this fixture proves is that the module now NAMES the gap in `warnings`.
  partialOverrideCollapse = eval [
    nixusbStub
    nixnetStub
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixnet.peers.host-b.hostnames = [ "host-b" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers.host-a.host = "host-a";
    }
  ];

  # THE FOLLOW-UP FIX: `excludePeers` is the declarative way to drop a permanent, named peer from
  # the pool while keeping the derivation from nixnet LIVE (a future nixnet peer still joins
  # automatically). A host using it correctly must see cfg.peers exactly equal the exclude-aware
  # derivation, and -- the whole point -- raise NO collapse warning, unlike the hand-written
  # `peers = {...}` shape it replaces.
  excludePeersUsed = eval [
    nixusbStub
    nixnetStub
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixnet.peers.host-b.hostnames = [ "host-b" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.excludePeers = [ "host-b" ];
    }
  ];

  # The OLD shape `excludePeers` exists to replace, still exercised: a hand-written wholesale
  # `peers = {...}` that drops a peer nixnet could still derive must still warn -- excludePeers
  # existing does not make this case stop being suspicious, it makes it stop being NECESSARY.
  manualExcludeInsteadOfOption = eval [
    nixusbStub
    nixnetStub
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixnet.peers.host-b.hostnames = [ "host-b" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers = { host-a.host = "host-a"; };
    }
  ];

  rtOk = eval [
    nixiamStub
    { nixiam.posix.deviceGroups.audio = 403; nixaudio.rt.enable = true; }
  ];

  rtBadGroup = eval [
    nixiamStub
    # nixiam composed, but the group nixaudio.rt names is not in its registry.
    { nixiam.posix.deviceGroups.video = 401; nixaudio.rt.enable = true; }
  ];

  rtNoNixiam = eval [{ nixaudio.rt.enable = true; }];

  homePlane = evalHome [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.fabric.peers.host-a.host = "host-a";
      # A device declared right on the home-manager plane -- proves catalogue.nix's import into
      # home/fabric-sync.nix actually reaches this plane rather than only the two NixOS-side ones.
      nixaudio.devices.dock-mic.match."device.name" = "alsa_card.usb-dock";
    }
  ];

  # ── Backend fixtures ────────────────────────────────────────────────────────────────────────
  #
  # `composed` above already carries `fabric.enable = true`, so it is also the plain NixOS-plane
  # backend fixture (backend.enable follows fabric.enable) -- reused rather than duplicated, so the
  # "a fabric host has a backend" wiring is exercised by the same fixture the fabric checks use.

  # The same host, having stated that it has real Intel DSP audio hardware.
  backendSof = eval [
    nixusbStub
    nixnetStub
    inventory
    {
      nixnet.peers.host-a.hostnames = [ "host-a" ];
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.14";
      nixaudio.backend.sofFirmware.enable = true;
    }
  ];

  # The backend WITHOUT the fabric: a host that wants its audio declared and joins no device pool.
  # The supported direction of the two options' relationship (the other one is rejected, below).
  backendOnly = eval [{ nixaudio.backend.enable = true; }];

  # Neither enabled: nothing at all should be published, so a host that has not opted in cannot
  # find backend packages appearing in its own reconciler.
  backendOff = eval [{ }];

  # The unsupported direction: a fabric with its backend switched off. Rendered config files for
  # daemons nothing installed.
  fabricWithoutBackend = eval [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.6";
      nixaudio.fabric.peers.other.host = "host-c";
      nixaudio.backend.enable = false;
    }
  ];

  # The Arch/system-manager plane, where the backend is packages rather than options.
  archPlane = evalArch [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.10";
      nixaudio.fabric.peers.other.host = "host-c";
    }
  ];

  missingDaemonUser = evalWithoutDaemonUser [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.6";
      nixaudio.fabric.peers.other.host = "host-c";
    }
  ];

  monitored = eval [
    nixwatchStub
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.6";
      nixaudio.fabric.peers.other.host = "host-c";
      nixwatch.checks.audio-fabric.channel = "operator-alerts";
    }
  ];

  archPlaneSof = evalArch [
    {
      nixaudio.fabric.enable = true;
      nixaudio.fabric.listen.address = "203.0.113.10";
      nixaudio.fabric.peers.other.host = "host-c";
      nixaudio.backend.sofFirmware.enable = true;
    }
  ];

  # Fixtures for ../lib/resolve.nix's branches that no live table entry exercises. Written as the
  # entries the module would hand it (table key already attached as `name`), so these test the real
  # functions rather than a paraphrase of them.
  resolveFixtures = [
    { name = "repoapp"; arch = "repoapp"; nixpkgs = "repoapp"; nixosOption = null; }
    { name = "aurapp"; arch = "aurapp"; aur = true; nixpkgs = null; nixosOption = null; }
    { name = "nowhere-on-arch"; arch = null; nixpkgs = "nowhere"; nixosOption = null; }
    { name = "option-provided"; arch = "optpkg"; nixpkgs = null; nixosOption = "services.example.enable"; }
    { name = "blob"; arch = "blob"; nixpkgs = "blob"; nixosOption = null; firmware = true; gate = "someGate"; }
  ];

  # An entry naming BOTH channels -- the shadow the whole layer is built to make impossible. Kept
  # out of the list above so every other resolve check runs against a well-formed table.
  shadowFixture = [
    { name = "double"; arch = "double"; nixpkgs = "double"; nixosOption = "services.example.enable"; }
  ];

  backendEntries = lib.mapAttrsToList (n: v: v // { name = n; }) backendTable.packages;
  rejectedNames = lib.attrNames backendTable.rejected;

  # Every list a host could install FROM, on either plane, for one fixture. What a rejected name
  # must never appear in.
  allOutputs = c:
    let b = c.config.nixaudio.backend;
    in b.archPackages ++ b.aurPackages ++ b.packageNames ++ b.firmwareNames;

  pkgNames = list: map (p: p.pname or p.name or "?") list;

  names = c: map (d: d.name) c.config.nixaudio.resolvedDevices;
  rules = c: c.config.nixaudio.namingConfig;
  catalogue = c: c.config.nixaudio.fabric.catalogue;

  # The generated config carries an explanatory header that NAMES the unstable properties in order
  # to warn against them. Scanning the raw text for those names therefore always "finds" them, in
  # the comment. Strip comment lines first so the check tests the actual matchers.
  effectiveRules = c:
    lib.concatStringsSep "\n"
      (builtins.filter
        (line: !(lib.hasPrefix "#" (lib.trim line)))
        (lib.splitString "\n" (rules c)));

  countInfix = needle: haystack:
    (builtins.length (lib.splitString needle haystack)) - 1;
  listenerArgs = c: (builtins.head c.config.nixaudio.fabric.pulseConfig."50-fabric-listener"."pulse.cmd").args;

  expectations = [
    {
      name = "only USB devices carrying the audio tag are derived";
      ok = lib.sort (a: b: a < b) (names composed) == [ "hyperx" "shure" ];
    }
    {
      name = "PipeWire's 0x-prefixed vendor/product ids are emitted, not nixusb's bare hex";
      ok = lib.hasInfix ''device.vendor.id = "0x03f0"'' (rules composed);
    }
    {
      name = "a device with a serial is narrowed by a bus-id regex";
      ok = lib.hasInfix ''device.bus-id = "~.*C1V51706C2.*"'' (rules composed);
    }
    {
      name = "a device without a serial emits no bus-id matcher";
      # Two audio devices are declared but only hyperx has a serial, so exactly one bus-id
      # matcher must exist -- proving the serial-less Shure did not get an empty or bogus one.
      ok = countInfix "device.bus-id" (effectiveRules composed) == 1;
    }
    {
      name = "unstable properties are never matched on";
      ok = !(lib.hasInfix "api.alsa.path" (effectiveRules composed))
        && !(lib.hasInfix "device.bus-path" (effectiveRules composed));
    }
    {
      name = "a device with no priority declared gets no priority.session rule at all";
      ok = countInfix "priority.session" (effectiveRules composed) == 0;
    }
    {
      name = "a declared priority reaches the generated WirePlumber config, matched on identity plus media.class -- never a name";
      ok =
        let r = effectiveRules withPriority;
        in lib.hasInfix ''device.vendor.id = "0x03f0"'' r
          && lib.hasInfix ''media.class = "Audio/Sink"'' r
          && lib.hasInfix "priority.session = 2000" r;
    }
    {
      name = "sink and source priorities are independent: declaring one never emits, duplicates onto, or overwrites the other";
      ok =
        let r = effectiveRules withPriority;
        in lib.hasInfix "priority.session = 2000" r # hyperx sink
          && lib.hasInfix "priority.session = 1500" r # hyperx source -- a DIFFERENT value
          && lib.hasInfix "priority.session = 2200" r # shure source -- shure's sink was left alone
          # exactly those three -- proves shure's un-declared sink emitted no fourth rule, and
          # neither hyperx value leaked onto shure or onto the other axis.
          && countInfix "priority.session" r == 3;
    }
    {
      name = "a priority for a device name nothing resolves to is REJECTED";
      ok = builtins.length (failed unknownPriority) == 1;
    }
    {
      name = "a valid priority declaration raises no assertion";
      ok = failed withPriority == [ ];
    }
    {
      name = "peers are derived from nixnet, addressed by its published name";
      ok = composed.config.nixaudio.fabric.peers.host-a.host == "host-a";
    }
    {
      name = "every nixnet peer joins the pool";
      ok = lib.attrNames composed.config.nixaudio.fabric.peers == [ "host-a" "host-b" ];
    }
    {
      name = "a fully-published fixture raises no warning at all";
      ok = composed.config.warnings == [ ];
    }
    {
      name = "a nixnet peer declared with no published hostnames is dropped from the pool, not just left empty";
      ok = lib.attrNames partialPeers.config.nixaudio.fabric.peers == [ "host-a" ];
    }
    {
      name = "dropping that peer is LOUD: it raises a warning naming it, rather than disappearing silently";
      ok =
        let w = partialPeers.config.warnings;
        in builtins.length w == 1 && lib.hasInfix "host-b" (builtins.head w);
    }
    {
      name = "the warning names only the incomplete peer, never the healthy one";
      ok = !(lib.hasInfix "host-a" (builtins.head partialPeers.config.warnings));
    }
    {
      name = "a partial peer raises a warning, not an assertion -- eval succeeds with the healthy peer still usable";
      ok = failed partialPeers == [ ];
    }
    {
      name = "a nested-key partial override still collapses cfg.peers to just the hand-written entry (the bug itself, unchanged by the defense)";
      ok = lib.attrNames partialOverrideCollapse.config.nixaudio.fabric.peers == [ "host-a" ];
    }
    {
      name = "...but is no longer silent: a warning names the peer nixnet could still derive";
      ok =
        let w = partialOverrideCollapse.config.warnings;
        in builtins.length w == 1 && lib.hasInfix "host-b" (builtins.head w);
    }
    {
      name = "the collapse warning does not fire on a healthy, fully-derived fixture";
      ok = composed.config.warnings == [ ];
    }
    {
      name = "the collapse warning does not fire on manyPeers either (no override at all)";
      ok = manyPeers.config.warnings == [ ];
    }
    {
      name = "excludePeers actually drops the named peer from cfg.peers";
      ok = lib.attrNames excludePeersUsed.config.nixaudio.fabric.peers == [ "host-a" ];
    }
    {
      name = "excludePeers keeps the derivation live: an unexcluded peer still joins automatically";
      ok = excludePeersUsed.config.nixaudio.fabric.peers.host-a.host == "host-a";
    }
    {
      name = "using excludePeers correctly raises NO collapse warning -- the whole point of the follow-up fix";
      ok = excludePeersUsed.config.warnings == [ ];
    }
    {
      name = "the hand-written shape excludePeers replaces still warns -- excludePeers existing does not silence a genuine accident";
      ok =
        let w = manualExcludeInsteadOfOption.config.warnings;
        in builtins.length w == 1 && lib.hasInfix "host-b" (builtins.head w);
    }
    {
      name = "...and that warning actively points at excludePeers as the fix";
      ok = lib.hasInfix "excludePeers" (builtins.head manualExcludeInsteadOfOption.config.warnings);
    }
    {
      name = "the listener binds the address given, never a silent 0.0.0.0";
      ok = lib.hasInfix "listen=203.0.113.14" (listenerArgs composed);
    }
    {
      name = ''listen.address = "any" is the ONLY way to get 0.0.0.0'';
      ok = lib.hasInfix "listen=0.0.0.0" (listenerArgs (eval [
        nixusbStub
        nixnetStub
        {
          nixaudio.fabric.enable = true;
          nixaudio.fabric.listen.address = "any";
          nixaudio.fabric.peers.p.host = "h";
        }
      ]));
    }
    {
      name = "fabric tunnels get their own data loop";
      ok = composed.config.nixaudio.fabric.pipewireConfig."50-fabric-loops"."context.properties"."context.num-data-loops" == 2;
    }
    # Mirror deprioritisation moved OUT of a WirePlumber fragment and into the tunnel's own module
    # properties, because these tunnels are created by pipewire-pulse and no WirePlumber monitor
    # rule is ever evaluated against them. The old `stream.rules` fragment matched nothing at all on
    # every host that ran it, so asserting on rendered text would only prove the text exists.
    {
      name = "mirrored peer devices are deprioritised, via the daemon's tunnel properties";
      ok = composed.config.nixaudio.fabric.daemon.settings.mirrorPriority == 0;
    }
    {
      name = "the daemon is told the listen address, so the probe can assert a real socket";
      ok = composed.config.nixaudio.fabric.daemon.settings.listen == "203.0.113.14";
    }

    # ── The carrier: the ONE mechanism that makes node-level rules possible at all ─────────────
    #
    # These exist because the previous generator produced rules that were syntactically fine,
    # rendered into the file, and matched nothing — on every host, silently, for the module's whole
    # life. A check that only asserted "a priority rule was rendered" would have passed throughout.
    # So each of these asserts something about WHICH OBJECT the rule can match.
    {
      name = "the device rule mints the carrier, so node rules have something to match";
      ok = lib.hasInfix ''alsa.nixaudio.device = "hyperx"'' withPriority.config.nixaudio.namingConfig;
    }
    {
      name = "the carrier is in the alsa.* namespace WirePlumber actually copies onto nodes";
      # Not cosmetic: the copy loop is a prefix filter on `alsa.` / `api.alsa.card.`, so a carrier
      # minted anywhere else reaches no node and the rules go quietly dead again.
      ok = lib.hasPrefix "alsa." "alsa.nixaudio.device";
    }
    {
      name = "the priority rule matches the carrier and media.class, never device identity";
      # The dead shape was `device.vendor.id + media.class`: no device object has media.class and no
      # node object has device.vendor.id, so it described an object that cannot exist. The rendered
      # priority rule must therefore contain NO device.* identity key.
      ok =
        let
          rules = withPriority.config.nixaudio.namingConfig;
          priorityBlocks = builtins.filter
            (block: lib.hasInfix "priority.session" block)
            (lib.splitString "}\n{" rules);
        in
        priorityBlocks != [ ]
        && lib.all
          (block:
            lib.hasInfix "alsa.nixaudio.device" block
            && lib.hasInfix "media.class" block
            && !(lib.hasInfix "device.vendor.id" block)
            && !(lib.hasInfix "device.bus-id" block))
          priorityBlocks;
    }
    {
      name = "node.nick is set from a NODE rule, not from the device rule where it is inert";
      ok =
        let
          rules = withPriority.config.nixaudio.namingConfig;
          nickBlocks = builtins.filter
            (block: lib.hasInfix "node.nick" block)
            (lib.splitString "}\n{" rules);
        in
        nickBlocks != [ ] && lib.all (block: lib.hasInfix "alsa.nixaudio.device" block) nickBlocks;
    }
    {
      name = "a bare integer priority still works and renders no profile narrowing";
      ok = !(lib.hasInfix "device.profile.name" withPriority.config.nixaudio.namingConfig);
    }
    {
      name = "a priority aimed at one node of a multi-PCM card renders the profile narrowing";
      ok = lib.hasInfix ''device.profile.name = "HiFi: Speaker: sink"''
        profiledPriority.config.nixaudio.namingConfig;
    }
    {
      name = "state restore is left at WirePlumber's own default unless a host says otherwise";
      ok = !(lib.hasInfix "restore-default-targets" withPriority.config.nixaudio.namingConfig)
        && lib.hasInfix "node.restore-default-targets = false"
        noRestore.config.nixaudio.namingConfig;
    }

    # ── The guard ─────────────────────────────────────────────────────────────────────────────
    {
      name = "the guard unit is emitted on the NixOS plane and runs off wireplumber's start";
      ok =
        let unit = guarded.config.systemd.user.services.nixaudio-alsa-guard; in
        unit.wantedBy == [ "wireplumber.service" ]
        && unit.after == [ "wireplumber.service" ]
        && unit.bindsTo == [ "wireplumber.service" ]
        && unit.serviceConfig.Type == "oneshot";
    }
    {
      name = "the guard carries ConditionUser, so a stray root session cannot run it";
      ok = guarded.config.systemd.user.services.nixaudio-alsa-guard.unitConfig.ConditionUser == "alice";
    }
    {
      name = "the guard is emitted even on a host with the backend but no fabric";
      # The failure it repairs is a property of the ALSA enumeration, not of the device pool.
      ok = backendOnlyGuard.config.systemd.user.services ? nixaudio-alsa-guard;
    }
    {
      name = "no guard unit at all when the guard is disabled";
      ok = !(guardOff.config.systemd.user.services ? nixaudio-alsa-guard)
        && !(guardOff.config.systemd.user.timers ? nixaudio-alsa-guard);
    }
    {
      name = "the periodic re-check can be turned off without losing the start-triggered one";
      ok = (guardNoTimer.config.systemd.user.services ? nixaudio-alsa-guard)
        && !(guardNoTimer.config.systemd.user.timers ? nixaudio-alsa-guard);
    }
    {
      name = "device reservation is disabled by default, in the profile the session actually uses";
      ok = lib.hasInfix "monitor.alsa.reserve-device = disabled"
        composed.config.nixaudio.guard.wireplumberConfig
      && lib.hasInfix "main =" composed.config.nixaudio.guard.wireplumberConfig;
    }
    {
      name = "a host that needs the reservation handshake can keep it, and gets no fragment";
      ok = reserveOn.config.nixaudio.guard.wireplumberConfig == "";
    }

    # ── dropIns: exactly one plane may place the fragments ────────────────────────────────────
    {
      name = "the NixOS plane claims the fragments by default";
      ok = composed.config.nixaudio.dropIns == "system"
        && composed.config.environment.etc ? "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf";
    }
    {
      name = "the home plane claims them by default when it is the only plane";
      ok = homePlane.config.nixaudio.dropIns == "user"
        && homePlane.config.xdg.configFile ? "pipewire/pipewire-pulse.conf.d/50-nixaudio-fabric-listener.conf";
    }
    {
      name = "the home plane places NO drop-in when a system plane owns them";
      # This is the fix for a deterministic, every-single-boot listener failure: PipeWire
      # CONCATENATES array sections across search roots, so two copies of the pulse fragment load
      # module-native-protocol-tcp twice and the second bind always fails.
      ok = !(homeSystemDropIns.config.xdg.configFile ? "pipewire/pipewire-pulse.conf.d/50-nixaudio-fabric-listener.conf")
        && !(homeSystemDropIns.config.xdg.configFile ? "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf");
    }
    {
      name = "the home plane still places the daemon's OWN config, which is not a drop-in";
      ok = homeSystemDropIns.config.xdg.configFile ? "nixaudio/fabric.json";
    }
    {
      name = "the system-manager plane places no drop-in when the user plane owns them";
      ok = !(archUserDropIns.config.environment.etc ? "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf");
    }
    {
      name = "the system-manager plane owns the generated daemon config";
      ok = archPlane.config.environment.etc ? "nixaudio/fabric.json";
    }
    {
      name = "evaluates with neither nixusb nor nixnet composed";
      ok = failed standalone == [ ] && names standalone == [ "internal" ];
    }
    {
      name = "a fabric with no peers at all is REJECTED";
      ok = builtins.length (failed noPeers) == 1;
    }
    {
      name = "redeclaring a nixusb-provided device is REJECTED";
      ok = builtins.length (failed collision) >= 1;
    }
    {
      name = "a valid composed host raises no assertion";
      ok = failed composed == [ ];
    }
    {
      # The option surface is name -> host because that is how a human declares it; the daemon's
      # table is host -> name because that is what it dials. The inversion has to actually happen.
      name = "the daemon's peer table is inverted from the option surface";
      ok =
        let conf = composed.config.nixaudio.fabric.daemon.settings;
        in conf.peers ? "host-a" && conf.peers."host-a" == "host-a";
    }
    {
      name = "the daemon config carries the configured port and loop";
      ok =
        let conf = composed.config.nixaudio.fabric.daemon.settings;
        in conf.port == 4713 && conf.loop == "fabric-loop.0";
    }
    {
      name = "the daemon runs as a user service, not a system one";
      # The audio graph belongs to a user session; there is no system-wide PipeWire to attach to.
      ok = composed.config.systemd.user.services ? fabric-sync;
    }
    {
      name = "a NixOS daemon without an owner is REJECTED";
      ok = builtins.length (failed missingDaemonUser) == 1;
    }
    {
      name = "the NixOS daemon owner gets device access and lingering";
      ok = lib.elem "audio" composed.config.users.users.test-user.extraGroups
        && composed.config.users.users.test-user.linger;
    }
    {
      name = "the NixOS daemon and guard are fenced to the declared user";
      ok = composed.config.systemd.user.services.fabric-sync.unitConfig.ConditionUser == "test-user"
        && composed.config.systemd.user.services.nixaudio-alsa-guard.unitConfig.ConditionUser == "test-user";
    }
    {
      name = "the health probe is available even without nixwatch composed";
      ok = standalone.config.nixaudio.fabric.healthCheck != null;
    }
    {
      name = "no nixwatch check is registered when nixwatch is absent";
      # Defining an option that does not exist is an eval error, so the guard has to hold.
      ok = !(standalone.config ? nixwatch);
    }
    {
      name = "nixwatch gets a two-tick deadline without claiming the operator's channel";
      ok = monitored.config.nixwatch.checks.audio-fabric.deadline == "10m"
        && monitored.config.nixwatch.checks.audio-fabric.interval == "5m"
        && monitored.config.nixwatch.checks.audio-fabric.channel == "operator-alerts";
    }
    {
      name = "the catalogue lists this host's own devices under their bare stable name";
      ok =
        let entry = (catalogue composedWithExplicit)."hyperx" or null;
        in entry != null
          && entry.origin == "local"
          && entry.known == "declared"
          && entry.description == "hyperx";
    }
    {
      name = "the catalogue lists an explicitly-declared (non-USB) device locally too";
      ok = ((catalogue composedWithExplicit)."internal-codec" or { }).origin or null == "local";
    }
    {
      name = "the catalogue projects fleet-shared USB devices onto every peer, keyed <peer>.<device>";
      ok =
        let entry = (catalogue composedWithExplicit)."host-a.hyperx" or null;
        in entry != null
          && entry.origin == "peer"
          && entry.peer == "host-a"
          && entry.known == "fleet-shared"
          # A peer's description is stamped by ITS OWN config, which this evaluation never sees --
          # asserting null here is what keeps this module from pretending to know it.
          && entry.description == null;
    }
    {
      # THE thing this catalogue must never do: claim a peer has hardware that is actually only
      # wired into THIS host. Mutation-proven: dropping the `source == "usb"` filter in
      # modules/catalogue.nix's `usbDeviceNames` (projecting ALL of cfg.resolvedDevices instead)
      # turns this check red immediately, with every other check above still green -- restoring the
      # filter turns it back green. That is the exact defect a careless "just mirror everything I
      # have" implementation would ship.
      name = "an explicitly-declared (non-USB) device is NEVER projected onto a peer";
      ok = !((catalogue composedWithExplicit) ? "host-a.internal-codec");
    }
    {
      # Mutation-proven the other direction: composed has 2 peers, manyPeers has 3, both fixtures
      # share the SAME { hyperx, shure } USB inventory. Hardcoding either count alone could pass by
      # coincidence (e.g. an implementation that always emits exactly 4 entries regardless of peer
      # count); asserting both counts scale together with the peer set is what actually proves "no
      # fixed peer count" rather than merely "works for the one fixture someone thought to write".
      name = "the peer catalogue scales with the actual peer set, not a fixed count";
      ok =
        let
          countPeerEntries = c:
            builtins.length (lib.attrNames (lib.filterAttrs (_: v: v.origin == "peer") (catalogue c)));
        in
        countPeerEntries composed == 2 * 2
        && countPeerEntries manyPeers == 3 * 2
        && (catalogue manyPeers) ? "host-c.shure";
    }
    {
      name = "a local device name colliding with a <peer>.<device> key is REJECTED";
      ok = builtins.length (failed catalogueCollision) == 1;
    }
    {
      name = "the home-manager plane also computes the catalogue, from its own local devices";
      # Proves catalogue.nix's import reaches the home-manager plane too, not only the two
      # NixOS-side ones (modules/default.nix, system-manager/default.nix) -- see home/fabric-sync.nix.
      ok = ((catalogue homePlane)."dock-mic" or { }).origin or null == "local";
    }
    {
      name = "rt limits name the group and never number it";
      ok =
        let out = rtOk.config.nixaudio.rt.limitsConfig;
        in lib.hasInfix "@audio - nice -11" out
          && lib.hasInfix "@audio - rtprio" out
          && !(lib.hasInfix "403" out);
    }
    {
      name = "rt emits the nice limit that was actually missing in the wild";
      ok = builtins.any (l: l.item == "nice" && l.value == "-11") rtOk.config.security.pam.loginLimits;
    }
    {
      name = "memlock is not raised unless asked for";
      # Raising a limit nothing requests is a change without a reason.
      ok = !(builtins.any (l: l.item == "memlock") rtOk.config.security.pam.loginLimits);
    }
    {
      name = "a group nixiam does not declare is REJECTED when nixiam is composed";
      ok = builtins.length (failed rtBadGroup) == 1;
    }
    {
      name = "rt makes no assertion about groups when nixiam is absent";
      # The distro ships an `audio` group; without the registry there is nothing to check against.
      ok = failed rtNoNixiam == [ ];
    }
    {
      name = "the home-manager plane places user config and a user unit";
      ok =
        let c = homePlane.config;
        in (c.xdg.configFile ? "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf")
          && (c.xdg.configFile ? "nixaudio/fabric.json")
          && (c.systemd.user.services ? fabric-sync);
    }
    {
      name = "the home-manager unit uses home-manager's capitalised shape";
      # NixOS's flat description/serviceConfig shape would silently produce a broken unit here.
      ok =
        let u = homePlane.config.systemd.user.services.fabric-sync;
        in (u ? Unit) && (u ? Service) && (u ? Install) && !(u ? serviceConfig);
    }
    {
      name = "the home plane points the daemon at the user's own config path";
      ok = builtins.any
        (e: lib.hasInfix "NIXAUDIO_FABRIC_CONFIG=/home/test/.config/nixaudio/fabric.json" e)
        homePlane.config.systemd.user.services.fabric-sync.Service.Environment;
    }
    {
      name = "the home plane can run only the daemon against system-manager's config";
      ok = (homeExternalDaemon.config.systemd.user.services ? fabric-sync)
        && !(homeExternalDaemon.config.xdg.configFile ? "nixaudio/fabric.json")
        && builtins.any
        (e: e == "NIXAUDIO_FABRIC_CONFIG=/etc/nixaudio/fabric.json")
        homeExternalDaemon.config.systemd.user.services.fabric-sync.Service.Environment;
    }

    # ── The backend: the universal set ────────────────────────────────────────────────────────
    {
      name = "the whole universal backend reaches archPackages -- exactly it, nothing else";
      # Named literally rather than derived from the table: a check that recomputes what it is
      # checking passes no matter what the table says, including when the table is wrong.
      ok = lib.sort (a: b: a < b) archPlane.config.nixaudio.backend.archPackages == [
        "alsa-utils"
        "pipewire"
        "pipewire-alsa"
        "pipewire-audio"
        "pipewire-pulse"
        "pipewire-zeroconf"
        "wireplumber"
      ];
    }
    {
      name = "pipewire-pulse is part of the declared backend, not an assumption the fabric makes";
      # The fabric's own listener is loaded into it (modules/fabric.nix), so a host that got
      # everything here EXCEPT this one would render a listener config for a daemon it never got.
      ok = lib.elem "pipewire-pulse" archPlane.config.nixaudio.backend.archPackages;
    }
    {
      name = "wireplumber is part of it too -- without it there are no device nodes to name";
      ok = lib.elem "wireplumber" archPlane.config.nixaudio.backend.archPackages;
    }
    {
      name = "alsa-utils is backend, not a desktop extra: it is what finds a hardware mute";
      ok = lib.elem "alsa-utils" archPlane.config.nixaudio.backend.archPackages;
    }
    {
      name = "no backend entry is AUR-only, and the AUR list is published anyway";
      ok = archPlane.config.nixaudio.backend.aurPackages == [ ];
    }
    {
      name = "every backend entry has a real Arch package, so nothing falls through to nixpkgs there";
      ok = archPlane.config.nixaudio.backend.unavailableOnArch == [ ];
    }
    {
      name = "the Arch plane installs NOTHING from nixpkgs -- it publishes names and stops";
      # A nixpkgs copy of a daemon whose distro copy is already running and first on PATH is not
      # redundancy, it is a second, competing install.
      ok = archPlane.config.environment.systemPackages == [ ];
    }

    # ── The backend: the hardware gate ────────────────────────────────────────────────────────
    {
      name = "sof-firmware is ABSENT by default -- a container or a VM must not carry a DSP image";
      ok = !(lib.elem "sof-firmware" archPlane.config.nixaudio.backend.archPackages)
        && !(lib.elem "sof-firmware" composed.config.nixaudio.backend.packageNames)
        && composed.config.nixaudio.backend.firmwareNames == [ ];
    }
    {
      name = "sof-firmware appears once the host declares the hardware, on BOTH planes";
      ok = lib.elem "sof-firmware" archPlaneSof.config.nixaudio.backend.archPackages
        && backendSof.config.nixaudio.backend.firmwareNames == [ "sof-firmware" ];
    }
    {
      name = "the gate moves ONLY that entry -- the rest of the selection is byte-identical";
      ok =
        let
          off = lib.sort (a: b: a < b) archPlane.config.nixaudio.backend.archPackages;
          on = lib.sort (a: b: a < b) archPlaneSof.config.nixaudio.backend.archPackages;
        in
        lib.subtractLists off on == [ "sof-firmware" ] && lib.subtractLists on off == [ ];
    }
    {
      name = "firmware is delivered as firmware, never as a package on PATH";
      # `hardware.firmware` is the kernel's search path; environment.systemPackages is not, and a
      # DSP image on $PATH is one the kernel will never find.
      ok =
        let c = backendSof.config;
        in pkgNames c.hardware.firmware == [ "sof-firmware" ]
          && !(lib.elem "sof-firmware" (pkgNames c.environment.systemPackages));
    }
    {
      name = "every gate the table names is answered by the module, and every answer is used";
      # The two halves of a gate live in different files -- the entry that names it, and the option
      # that answers it -- so a rename on either side would drop that entry silently and completely.
      # Checked in both directions: an unanswered gate, and an option nothing is gated on.
      ok =
        let
          declared = lib.unique (lib.filter (g: g != null) (map (e: e.gate or null) backendEntries));
          answered = lib.attrNames archPlane.config.nixaudio.backend.hardwareGates;
        in
        lib.sort (a: b: a < b) declared == lib.sort (a: b: a < b) answered
        && declared != [ ];
    }

    # ── The plane divide: what NixOS's own options provide, and must not be installed twice ────
    {
      name = "on NixOS this module installs EXACTLY the one entry no services.pipewire option provides";
      ok = composed.config.nixaudio.backend.packageNames == [ "alsa-utils" ];
    }
    {
      name = "the six option-provided entries are published as such, each naming its own option";
      ok = composed.config.nixaudio.backend.providedByNixosOptions == {
        pipewire = "services.pipewire.enable";
        wireplumber = "services.pipewire.wireplumber.enable";
        "pipewire-pulse" = "services.pipewire.pulse.enable";
        "pipewire-alsa" = "services.pipewire.alsa.enable";
        "pipewire-audio" = "services.pipewire.enable";
        "pipewire-zeroconf" = "services.pipewire.enable";
      };
    }
    {
      name = "THE ANTI-SHADOWING INVARIANT: nothing an option provides is also installed as a package";
      ok =
        let
          b = composed.config.nixaudio.backend;
          provided = lib.attrNames b.providedByNixosOptions;
        in
        lib.intersectLists provided (b.packageNames ++ b.firmwareNames) == [ ]
        # ...and the same again at the entry level, where the table could break it
        && resolve.shadowed backendEntries == [ ];
    }
    {
      name = "an entry naming BOTH a nixpkgs attribute and a NixOS option is caught, not merged";
      # Non-vacuity for the check above: the invariant holds for the real table, and the mechanism
      # that would report a violation actually reports one.
      ok = resolve.shadowed shadowFixture == [ "double" ];
    }
    {
      name = "the installed NixOS package set carries alsa-utils and NO second PipeWire";
      ok =
        let installed = pkgNames composed.config.environment.systemPackages;
        in lib.elem "alsa-utils" installed
          && !(lib.elem "pipewire" installed)
          && !(lib.elem "wireplumber" installed);
    }
    {
      name = "the NixOS plane switches on the options that ARE the packages there";
      ok =
        let p = composed.config.services.pipewire;
        in p.enable == true && p.pulse.enable == true && p.wireplumber.enable == true;
    }
    {
      name = "BOTH PLANES SELECT THE SAME BACKEND -- only the delivery differs";
      # The one claim the plane divide rests on. Compared by table key rather than by package name,
      # so it stays a real comparison the day an Arch name and a nixpkgs attribute diverge.
      ok = lib.sort (a: b: a < b) composed.config.nixaudio.backend.selection
        == lib.sort (a: b: a < b) archPlane.config.nixaudio.backend.selection;
    }
    {
      name = "...and they still agree once a hardware gate is on";
      ok = lib.sort (a: b: a < b) backendSof.config.nixaudio.backend.selection
        == lib.sort (a: b: a < b) archPlaneSof.config.nixaudio.backend.selection
        && lib.elem "sof-firmware" backendSof.config.nixaudio.backend.selection;
    }

    # ── The three that are installed in the wild and must never be declared ────────────────────
    {
      name = "the rejected list still names the two that were ruled out, with reasons";
      # Guards the check below from passing because the list quietly became empty.
      ok = lib.sort (a: b: a < b) rejectedNames == [ "alsa-firmware" "alsa-plugins" ]
        && builtins.all (n: builtins.isString backendTable.rejected.${n}) rejectedNames;
    }
    {
      name = "no rejected name reaches ANY output list, on either plane, gated or not";
      ok = builtins.all
        (n: !(lib.elem n (allOutputs archPlane ++ allOutputs archPlaneSof ++ allOutputs composed ++ allOutputs backendSof)))
        rejectedNames;
    }
    {
      name = "zeroconf IS declared -- rejected as a fabric transport is not the same as unwanted";
      # The distinction the entry itself is about: this module refuses to route the device pool
      # over zeroconf, and still installs the package for the RAOP/AirPlay discovery it also
      # carries. Asserted so a future reader cannot "tidy it away" back into the rejected list on
      # the strength of fabric.nix's header alone.
      ok = lib.elem "pipewire-zeroconf" archPlane.config.nixaudio.backend.archPackages
        && !(lib.elem "pipewire-zeroconf" rejectedNames)
        # ...and it is NOT installed as a package on NixOS, where the pipewire derivation already
        # carries libpipewire-module-{zeroconf-discover,raop-discover,raop-sink}.so.
        && composed.config.nixaudio.backend.providedByNixosOptions."pipewire-zeroconf"
        == "services.pipewire.enable";
    }

    # ── enable/disable, both directions ───────────────────────────────────────────────────────
    {
      name = "the backend follows fabric.enable, because the fabric is written against it";
      ok = composed.config.nixaudio.backend.enable;
    }
    {
      name = "a fabric with its backend switched off is REJECTED";
      ok = builtins.length (failed fabricWithoutBackend) == 1;
    }
    {
      name = "the backend WITHOUT a fabric is supported: declared audio, no device pool";
      ok = failed backendOnly == [ ]
        && lib.elem "pipewire" backendOnly.config.nixaudio.backend.archPackages
        && backendOnly.config.nixaudio.backend.packageNames == [ "alsa-utils" ];
    }
    {
      name = "a host that enabled neither gets NOTHING published -- not a list it never asked for";
      ok =
        let b = backendOff.config.nixaudio.backend;
        in b.archPackages == [ ] && b.aurPackages == [ ] && b.packageNames == [ ]
          && b.firmwareNames == [ ] && b.providedByNixosOptions == { }
          && backendOff.config.environment.systemPackages == [ ];
    }

    # ── Resolution branches no live entry exercises ───────────────────────────────────────────
    {
      name = "an AUR entry is held back from archPackages and lands in aurPackages";
      # pacman -S fails the WHOLE transaction on an AUR name, so this separation is not cosmetic.
      ok = !(lib.elem "aurapp" (resolve.archPackages resolveFixtures))
        && resolve.aurPackages resolveFixtures == [ "aurapp" ];
    }
    {
      name = "an entry with no Arch package at all is reported by NAME, never as a null";
      ok = resolve.unavailableOnArch resolveFixtures == [ "nowhere-on-arch" ]
        && !(builtins.elem null (resolve.archPackages resolveFixtures))
        && !(builtins.elem null (resolve.aurPackages resolveFixtures));
    }
    {
      name = "an option-provided entry contributes to neither nixpkgs list";
      ok = !(lib.elem "optpkg" (resolve.packageNames resolveFixtures))
        && resolve.providedByNixosOptions resolveFixtures == {
        option-provided = "services.example.enable";
      };
    }
    {
      name = "firmware is separated from packageNames by the resolution itself, not by the caller";
      ok = resolve.firmwareNames resolveFixtures == [ "blob" ]
        && !(lib.elem "blob" (resolve.packageNames resolveFixtures));
    }
    {
      name = "a gated entry is dropped when its gate is off and kept when it is on";
      ok = resolve.selected { someGate = false; } resolveFixtures
        == lib.filter (e: e.name != "blob") resolveFixtures
        && resolve.selected { someGate = true; } resolveFixtures == resolveFixtures;
    }
    {
      name = "an empty selection resolves to empty lists, not to an error";
      ok = resolve.archPackages [ ] == [ ] && resolve.aurPackages [ ] == [ ]
        && resolve.packageNames [ ] == [ ] && resolve.unavailableOnArch [ ] == [ ];
    }
  ];

  failures = builtins.filter (e: !e.ok) expectations;
in
{
  # The one check here that is not a pure evaluation, and cannot be. "Does a RUNNING daemon notice
  # that its config changed" is a runtime property by definition -- no amount of evaluating options
  # can observe it, because the defect lives entirely in the gap between what the generated file
  # says and what a long-lived process still holds in memory. So this check actually executes the
  # daemon's discovery entry point against a config file that is rewritten underneath it. See
  # ./daemon-peer-reload.py's own header for the production failure it reproduces.
  daemon = pkgs.runCommand "nixaudio-daemon-checks"
    {
      nativeBuildInputs = [ pkgs.python3 pkgs.iproute2 ];
      # The fixture stands up a real loopback listener so the daemon's reachability probe runs for
      # real rather than being stubbed -- a stubbed probe could pass while the probe itself is what
      # is broken.
      FABRIC_SYNC = ../daemon/fabric-sync;
    } ''
    cd "$(mktemp -d)"
    python3 ${./daemon-peer-reload.py}
    touch $out
  '';

  purity = pkgs.runCommand "nixaudio-purity-checks" { } ''
    ${lib.optionalString (failures != [ ]) ''
      echo "nixaudio checks FAILED:" >&2
      ${lib.concatMapStringsSep "\n" (f: ''echo "  - ${f.name}" >&2'') failures}
      exit 1
    ''}
    echo "nixaudio: ${toString (builtins.length expectations)} checks passed"
    touch $out
  '';
}
