# Pure evaluation checks. Everything nixaudio produces is a pure function of declared data, so the
# whole contract is verifiable without a VM or a host. Both directions are proven throughout: the
# right output is generated, AND the inputs that must be rejected are.
{ pkgs, nixpkgs, nixaudioModule }:
let
  lib = nixpkgs.lib;

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

  # The daemon and monitor modules take `pkgs`, so it has to be threaded through as a specialArg --
  # these are the same real pkgs the flake check runs with, so the packaged daemon and health probe
  # are evaluated for real rather than against a stub that could hide a broken derivation.
  eval = modules: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      nixaudioModule
      { options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; }; }
      { options.warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; }; }
      { options.services.pipewire = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; }; }
      { options.environment.etc = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; }; }
      { options.environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; }; }
      { options.systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; }; }
      { options.security.pam.loginLimits = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; }; }
    ] ++ modules;
  };

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

  rtNoNixiam = eval [ { nixaudio.rt.enable = true; } ];

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
    {
      name = "mirrored peer devices are deprioritised in default-sink selection";
      ok = lib.hasInfix "priority.session = 0" composed.config.nixaudio.fabric.wireplumberConfig;
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
      name = "the health probe is available even without nixwatch composed";
      ok = standalone.config.nixaudio.fabric.healthCheck != null;
    }
    {
      name = "no nixwatch check is registered when nixwatch is absent";
      # Defining an option that does not exist is an eval error, so the guard has to hold.
      ok = !(standalone.config ? nixwatch);
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
        in countPeerEntries composed == 2 * 2
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
  ];

  failures = builtins.filter (e: !e.ok) expectations;
in
{
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
