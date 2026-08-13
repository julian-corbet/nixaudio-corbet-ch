# nixaudio.devices — give every audio device a stable name the whole fleet agrees on.
#
# WHY THIS IS NOT JUST COSMETIC
#
# PipeWire's own node names embed the machine's USB topology:
#
#   alsa_card.usb-HP__Inc_HyperX_Cloud_III_S_Wireless_C1V51706C2-00.2
#   api.alsa.path = hw:1
#   device.bus-path = pci-0000:00:14.0-usb-0:1.2.4:1.0
#
# The `hw:N` index depends on enumeration order, and the bus-path depends on which physical port the
# device is in. Move a headset from a laptop port to a dock port, or plug it into a different host,
# and both change. Anything downstream that pinned one of those strings silently stops resolving.
#
# That matters here more than usual, because the fabric's whole point is that a device on ANY host is
# reachable from EVERY host. A sink reference that only resolves on the machine the device happens to
# be plugged into defeats the exercise.
#
# ── WHAT IS ACTUALLY STABLE ─────────────────────────────────────────────────────────────────────
#
# Verified live against `pw-dump` on a real device rather than assumed:
#
#   device.vendor.id   = 0x03f0     <- stable, note the 0x prefix and lowercase hex
#   device.product.id  = 0x06be     <- stable
#   device.bus-id      = usb-HP__Inc_HyperX_Cloud_III_S_Wireless_C1V51706C2-00   <- stable, carries serial
#   device.serial      = HP__Inc_HyperX_Cloud_III_S_Wireless_C1V51706C2          <- mangled, NOT the raw serial
#   api.alsa.path      = hw:1       <- UNSTABLE, enumeration order
#   device.bus-path    = pci-...    <- UNSTABLE, physical port
#
# So the rules generated here match on vendor+product id, optionally narrowed by a substring match on
# `device.bus-id` when two units of one model must be told apart. Note `device.serial` is NOT the raw
# USB serial — PipeWire prefixes it with the manufacturer and product strings and mangles spaces to
# underscores — which is exactly the sort of thing that has to be checked rather than guessed.
#
# ── WHERE THE DEVICE LIST COMES FROM ────────────────────────────────────────────────────────────
#
# USB devices are not re-declared here. They come from `nixusb.devices` — the fleet's single USB
# inventory — filtered to those carrying the `audio` tag. Read defensively so nixusb stays an
# optional input: a host that has not adopted nixusb simply contributes nothing, and can still
# declare non-USB devices (an internal PCI codec, a virtual sink) through `nixaudio.devices` directly.
#
# ── WINNING THE DEFAULT-SINK / DEFAULT-SOURCE RACE ──────────────────────────────────────────────
#
# The live defect this exists to fix: a HyperX headset and a Shure studio interface, both plugged
# into the same host, both carry PipeWire's own ALSA-monitor-assigned `priority.session = 1109` for
# their sinks — verified live with `pw-dump`, an exact tie. WirePlumber's default-node picker breaks
# a tie by whichever enumerated last, which is exactly the `hw:N`/enumeration-order instability this
# module's whole naming scheme already exists to route around (see above).
#
# `nixaudio.priorities` is therefore bound to hardware identity, never to a node name or description
# that a stale WirePlumber state file could have cached — but it cannot be bound to it DIRECTLY,
# because no node object carries a hardware id. It is bound through a carrier property minted by the
# device rule; `carrierKey` below is where that mechanism is described, and it is worth reading
# before editing either rule, because the shape that looks obvious does not work and does not
# complain.
#
# A stale state file is a SECOND way the same symptom shows up, and priorities do not beat it: a
# default a human once chose is remembered per node and outranks any number declared here. That is
# deliberate (it is the same "the live choice wins" rule stated below), and `restoreDefaultTargets`
# is the switch for a host that wants declared priority to be authoritative instead.
#
# `nixaudio.priorities.<name>` lets a device explicitly outrank a rival instead of gambling on
# enumeration order. It is deliberately NOT part of `nixaudio.devices` or projected from
# `nixusb.devices`: it has to apply equally to a usb-derived device (which carries no field for it —
# nixusb's own schema is not this repo's to extend) and an explicitly-declared one, so it is its own
# small overlay, keyed by the same stable NAME `fromUsb`/`explicitDevices` already assign, applied
# after device identity is resolved rather than folded into how identity is declared.
#
# THIS IS A TIE-BREAKER, NOT A ROUTE PIN. This only ever affects an UNOPINIONATED app willing to
# accept whatever PipeWire
# currently calls the default. The moment an app pins a sink explicitly, or a human moves the
# default with `wpctl set-default`/`pw-link`, that live choice wins exactly as it would with no
# priority declared at all — a rebuild does not, and must not, reach into the running graph and force
# a stream to move.
#
# SINK AND SOURCE ARE INDEPENDENT because one physical device is routinely both, with opposite
# rankings. The defect this fixes IS that shape: a headset with good speakers and an acceptable mic
# should not have to lose default-source to a studio interface with a genuinely better mic just
# because that interface also exposes a sink nobody listens on. "Best speakers, worst microphone" is
# a legitimate preference a single number cannot express, so `priority.sink` and `priority.source`
# are two independently-settable fields, never one.
#
# NUMBER SPACE: positive integers only (`>= 1`), no declared ceiling.
#   - Zero and below are refused by the option's own type: a usable local endpoint needs a positive
#     WirePlumber session priority.
#   - No ceiling is declared because PipeWire's own ALSA-monitor-assigned `priority.session` for real
#     hardware is not a fixed, documented range: verified live across this fleet's own devices it
#     spans at least 664 (an HDMI output nobody wants first) to 2100 (a muted fallback microphone),
#     profile- and port-dependent, with nothing upstream promising that ceiling won't move the next
#     time a device or profile is added. `priority` only ever has to outrank whatever number the
#     SPECIFIC rival it is weighed against currently carries — a judgment call for whoever declares
#     it, not a global maximum this module would have to guess and could already be wrong about.
#   - Only `priority.session` is rendered, never `priority.driver`: the latter governs which
#     driver-capable node becomes the graph's clock source, an orthogonal concern from which node
#     `wpctl`/an app's "default" points at, and not what either the reported defect or this option is
#     about.
{ lib, config, ... }:
let
  cfg = config.nixaudio;

  # Defensive read: nixusb is a soft
  # dependency: if it is absent, `or { }` keeps evaluation working instead of exploding.
  usbDevices = config.nixusb.devices or { };

  audioUsbDevices = lib.filterAttrs
    (_: device: builtins.elem cfg.usbTag device.tags)
    usbDevices;

  # Project a nixusb entry onto a nixaudio device. The `0x` prefix is PipeWire's, not nixusb's --
  # nixusb stores bare hex because that is what udev's ATTRS{idVendor} uses. Translating between the
  # two representations is precisely this module's job.
  #
  # `source` is not cosmetic: it is what modules/catalogue.nix uses to decide which of THIS host's
  # devices it may assume also exist, by the same name, on a PEER host it has never evaluated.
  # nixusb.devices is the fleet's single inventory (one declaration, composed unchanged wherever
  # nixusb is imported -- see the README), so a "usb" entry is fleet-shared vocabulary; an
  # "explicit" entry is this host's own hand-declared hardware (a PCI codec, a virtual sink) that no
  # other host's config has any way of knowing about. Conflating the two would let the catalogue
  # claim a peer has a device that is actually only wired into THIS box.
  fromUsb = name: device: {
    inherit name;
    description = if device.description != "" then device.description else name;
    source = "usb";
    match = {
      "device.vendor.id" = "0x${device.vendorId}";
      "device.product.id" = "0x${device.productId}";
    } // lib.optionalAttrs (device.serial != null) {
      # `~` makes this a regex in WirePlumber's rule matcher. bus-id embeds the USB serial but also
      # the manufacturer and product strings, so an exact match would be brittle -- a substring match
      # on the serial is both stable and sufficient to disambiguate two units of one model.
      "device.bus-id" = "~.*${device.serial}.*";
    };
  };

  derivedDevices = lib.mapAttrsToList fromUsb audioUsbDevices;

  explicitDevices = lib.mapAttrsToList
    (name: device: {
      inherit name;
      description = if device.description != "" then device.description else name;
      source = "explicit";
      match = device.match;
    })
    cfg.devices;

  allDevices = derivedDevices ++ explicitDevices;

  # A priority is a NUMBER plus an optional profile to aim it at, but the overwhelmingly common case
  # is a device with exactly one sink and one source, where a bare integer says everything. So the
  # bare integer stays the surface and is coerced up, rather than making every host write
  # `sink.priority = 1200` to buy a narrowing axis it does not need.
  #
  # The narrowing axis is not optional in general: one ALSA card commonly spawns several sinks (an
  # internal codec with speakers plus every HDMI/DP output), and a rule that names only the device
  # and the media class stamps ONE number onto ALL of them. Measured on a real internal card, that
  # collapses a working 1000/696/680/664 ranking into a four-way tie and makes an unplugged HDMI
  # port as eligible to be the default output as the speakers.
  priorityType = lib.types.nullOr (lib.types.coercedTo
    lib.types.ints.positive
    (priority: { inherit priority; profile = null; })
    (lib.types.submodule {
      options = {
        priority = lib.mkOption {
          type = lib.types.ints.positive;
          example = 2000;
          description = "The `priority.session` value to stamp onto the matching node(s).";
        };

        profile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "HiFi: Speaker: sink";
          description = ''
            Narrow this priority to ONE node of a card that spawns several, by
            `device.profile.name`. Null (the default) applies it to every node of the declared media
            class, which is correct for a device with a single output or input and wrong for an
            internal codec.

            The value is WirePlumber's own profile-device name, as reported by
            `pw-dump` on the node you mean — read it off the running graph rather than guessing at
            its punctuation.

            NOT `card.profile.device`, which looks like it would do the same job and does not: it is
            a per-card ORDINAL whose meaning differs between cards. Measured on one host, index 0 is
            an HDMI output on the internal card and index 3 is the speakers, while on both USB
            devices index 3 is the sink — so a number that selects the right node on one card
            selects an arbitrary one on the next.
          '';
        };
      };
    }));

  # No override declared for this device: `null` on both axes means "leave WirePlumber's own
  # ALSA-monitor heuristic alone", i.e. render no priority.session rule at all for it (see
  # priorityRulesFor). This is the default every device gets unless named in `cfg.priorities`.
  noPriority = { sink = null; source = null; };

  # Layer the priority overlay onto the identity `fromUsb`/`explicitDevices` already resolved, keyed
  # by the same stable NAME -- see this file's header for why priority is not folded into either of
  # those instead. Every consumer downstream (rule generation, `nixaudio.resolvedDevices`) reads this
  # list, never `allDevices` directly, so `priority` is never missing where identity is present.
  resolvedDevices = map
    (device: device // { priority = cfg.priorities.${device.name} or noPriority; })
    allDevices;

  # A priority declared for a name nothing resolves to is a typo, or a device this host does not
  # actually compose (a nixusb tag never applied, a name that does not match `nixaudio.devices`) --
  # exactly the class of mistake `duplicateNames` below catches for the reverse case (two devices,
  # one name); this is one name, zero devices.
  unknownPriorityNames =
    lib.subtractLists (map (d: d.name) allDevices) (lib.attrNames cfg.priorities);

  # ── THE CARRIER, AND WHY THE OBVIOUS SHAPE DOES NOT WORK ──────────────────────────────────────
  #
  # A DEVICE and the NODES it spawns are two different objects with two different property sets, and
  # `monitor.alsa.rules` is evaluated separately against each. That fact killed the previous version
  # of this generator, silently, on every host that ever ran it:
  #
  #   * The identity keys -- device.vendor.id, device.product.id, device.bus-id -- are written by
  #     PipeWire's udev layer onto the DEVICE only (spa/plugins/alsa/alsa-udev.c). No node has any
  #     of them.
  #   * `media.class` is "Audio/Sink" or "Audio/Source" on the NODES. The device object carries
  #     "Audio/Device" and never matches either.
  #
  # So a matcher listing BOTH -- identity AND media.class, which is what this file used to render --
  # describes an object that does not exist. It matched the device (no media.class) never, and the
  # nodes (no identity keys) never. Every `nixaudio.priorities` declaration ever written was a
  # no-op, and nothing said so: a rule that matches nothing is not an error in WirePlumber, it is
  # just a rule that matches nothing. Reproduced live against the shipped text, with a
  # `media.class`-only control rule in the same file and the same restart proving the file was read.
  #
  # WHAT ACTUALLY BRIDGES THE TWO. WirePlumber's ALSA monitor copies device properties onto each
  # node it creates, but by a PREFIX FILTER rather than a fixed key list -- every key beginning
  # `alsa.` or `api.alsa.card.` (scripts/monitors/alsa.lua, "add api.alsa.card.* and alsa.*
  # properties for rule matching purposes"), and it does so BEFORE the node rule pass. Upstream put
  # that loop there for exactly this purpose.
  #
  # So the identity match stays where it already works -- on the device, unchanged, still pinned to
  # vendor/product/bus-id and never to a name -- and additionally mints one synthetic label under
  # `alsa.`. That label rides the copy onto every node of that card, where a second rule matches it
  # together with media.class. The hardware matcher is not weakened; a label derived from it is
  # simply carried somewhere the first matcher cannot reach.
  #
  # Verified end to end on real hardware (USB headset, USB interface, internal Intel DSP card):
  # a carrier under `alsa.` reaches the nodes, an otherwise identical carrier under a non-`alsa.`
  # namespace does not, and priority.session then lands on exactly the sink or source asked for.
  carrierKey = "alsa.nixaudio.device";

  renderMatch = match: lib.concatStringsSep "\n" (lib.mapAttrsToList
    (key: value: "        ${key} = \"${value}\"")
    match);

  mkMatchRule = match: actions: ''
    {
      matches = [
        {
    ${renderMatch match}
        }
      ]
      actions = {
        update-props = {
    ${lib.concatStringsSep "\n" (map (line: "      ${line}") actions)}
        }
      }
    }'';

  # The DEVICE rule: stable hardware identity in, the chosen name out. `device.description` and
  # `device.nick` are the device object's own; the carrier is what makes the node rules below
  # possible at all.
  mkRule = device: mkMatchRule device.match [
    ''device.description = "${device.description}"''
    ''device.nick = "${device.name}"''
    ''${carrierKey} = "${device.name}"''
  ];

  # The NICK rule, and it is a REAL fix rather than a reshuffle. `node.nick` used to be set in the
  # device rule above, where it is inert: it lands on the device object, and `node.nick` is matched
  # by neither half of the copy filter, so it never reached a single node. Node naming appeared to
  # work only through an accident of upstream's fallback chain -- alsa.lua substitutes
  # `device.nick` when a node's own `alsa.name` is the literal string "USB Audio", which every USB
  # audio-class card reports and no PCI card does. Measured on an internal Intel DSP card whose
  # device.nick was set correctly: its six nodes were named Speaker / HDMI 1 / HDMI 2 / HDMI 3 /
  # Stereo Microphone / Digital Microphone, i.e. the declared name reached none of them.
  #
  # Setting it from a node rule makes the declared name actually authoritative on every card type.
  mkNickRule = device: mkMatchRule
    {
      ${carrierKey} = device.name;
      "media.class" = "~^Audio/(Sink|Source)$";
    } [ ''node.nick = "${device.name}"'' ];

  # The PRIORITY rule: carrier + media.class, both node properties, so it describes an object that
  # exists. No identity keys here -- the device rule already did that work, and repeating it is what
  # made this unsatisfiable before.
  #
  # `profile` narrows further, and is not optional decoration on a multi-PCM card. One card can
  # spawn many sinks (an internal codec typically exposes speakers plus every HDMI/DP output), and
  # carrier + media.class alone stamps ONE number onto ALL of them -- measured: a single unnarrowed
  # rule flattened four sinks whose distinct 1000/696/680/664 ranking is the thing that keeps an
  # unplugged HDMI port from becoming the default output. `device.profile.name` is the key that
  # separates them.
  mkPriorityRule = device: mediaClass: value: mkMatchRule
    ({
      ${carrierKey} = device.name;
      "media.class" = mediaClass;
    } // lib.optionalAttrs (value.profile != null) {
      "device.profile.name" = value.profile;
    })
    [ "priority.session = ${toString value.priority}" ];

  # Zero, one or two extra rules per device -- sink and source are independent, so either, both or
  # neither may be declared (see this file's header for why one number cannot express both).
  priorityRulesFor = device:
    lib.optional (device.priority.sink != null) (mkPriorityRule device "Audio/Sink" device.priority.sink)
    ++ lib.optional (device.priority.source != null) (mkPriorityRule device "Audio/Source" device.priority.source);

  namingConfig = ''
    # Generated by nixaudio.devices -- do not edit.
    #
    # TWO PASSES, because a DEVICE and the NODES under it are different objects with different
    # properties, and this file is evaluated separately against each:
    #
    #   1. The DEVICE rule matches stable hardware identity -- vendor/product id, plus a bus-id
    #      substring where a serial disambiguates two units of one model. Never api.alsa.path or
    #      device.bus-path, both of which change when the device moves ports or the enumeration
    #      order shifts. It stamps the chosen name onto the device AND mints ${carrierKey}.
    #
    #   2. The NODE rules match that carrier plus media.class. They cannot match hardware identity
    #      directly: no node carries device.vendor.id, device.product.id or device.bus-id at all.
    #      The carrier reaches them because WirePlumber's ALSA monitor copies every device property
    #      prefixed `alsa.` or `api.alsa.card.` onto each node before applying these rules.
    #
    # A single rule listing identity AND media.class -- which is what this file used to generate --
    # describes no object that exists, and silently matched nothing on every host.
    monitor.alsa.rules = [
    ${lib.concatStringsSep "\n" (lib.concatMap
      (device: [ (mkRule device) (mkNickRule device) ] ++ priorityRulesFor device)
      resolvedDevices)}
    ]
  ''
  + lib.optionalString (!cfg.restoreDefaultTargets) ''

    # nixaudio.devices.restoreDefaultTargets = false
    wireplumber.settings = {
      node.restore-default-targets = false
    }
  '';

  duplicateNames =
    let
      names = map (d: d.name) resolvedDevices;
      counts = lib.groupBy lib.id names;
    in
    lib.attrNames (lib.filterAttrs (_: v: builtins.length v > 1) counts);
in
{
  options.nixaudio = {
    usbTag = lib.mkOption {
      type = lib.types.str;
      default = "audio";
      description = ''
        Which `nixusb.devices.<name>.tags` entry marks a USB device as an audio device this module
        should name.

        nixusb assigns no meaning to any tag — each consumer defines its own vocabulary — so this is
        nixaudio declaring which word it answers to, rather than a convention nixusb imposes.
      '';
    };

    devices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              Human-readable description shown locally and in the live endpoint manifest peers
              receive. Defaults to the attribute name.
            '';
          };

          match = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            example = lib.literalExpression ''
              {
                "device.name" = "alsa_card.pci-0000_00_1f.3-platform-skl_hda_dsp_generic";
              }
            '';
            description = ''
              PipeWire device properties to match on, as a WirePlumber rule matcher. Prefix a value
              with `~` to make it a regex.

              Use properties that survive a replug and a reboot. Verified stable: `device.vendor.id`
              (note the `0x` prefix), `device.product.id`, `device.bus-id`, and for fixed internal
              hardware `device.name` with its PCI path. Verified UNSTABLE, do not use:
              `api.alsa.path` (`hw:N`, enumeration order) and `device.bus-path` (physical port).

              USB devices should not be declared here at all — tag them in `nixusb.devices` instead
              and they are derived automatically, which keeps one inventory rather than two.
            '';
          };
        };

        config.description = lib.mkDefault name;
      }));
      default = { };
      description = ''
        Audio devices declared directly, for anything that is not a tagged USB device — an internal
        PCI codec, a virtual sink, a device on a bus nixusb does not cover.

        USB devices come from `nixusb.devices` automatically and must not be repeated here.
      '';
    };

    restoreDefaultTargets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Let WirePlumber keep remembering, across sessions, which sink and source a human last chose
        with `wpctl set-default` (its own `node.restore-default-targets`, whose upstream default
        this mirrors).

        READ THIS BEFORE CONCLUDING `nixaudio.priorities` DOES NOT WORK. A remembered choice
        OUTRANKS any priority declared here, and the memory is per node, in
        `~/.local/state/wireplumber/default-nodes`. Measured on a real host: a sink declared at 9000
        still lost the default to a sink at 1200 that the state file had pinned, and setting this to
        false moved the default to the 9000 sink in the same session. So on a machine that has been
        used for a while, priorities arbitrate only among nodes the state file has never seen — and
        that can be very few of them.

        It stays TRUE by default anyway, because that is what this module already promises
        everywhere else: `nixaudio.priorities` is documented as a tie-breaker for an unopinionated
        app, and the live choice wins. A human who moved their default output is the clearest possible expression of
        exactly that. Turning this off makes declared priority authoritative instead, at the price
        of a `wpctl set-default` no longer surviving a logout — which is a real preference about how
        the machine should behave, not a defect, so it is a switch and not a default.
      '';
    };

    priorities = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          sink = lib.mkOption {
            type = priorityType;
            default = null;
            example = 2000;
            description = ''
              `priority.session` this device's SINK (playback) node should carry, overriding
              whatever WirePlumber's ALSA monitor would otherwise assign it. `null` (the default)
              leaves that heuristic alone.

              A bare integer applies to EVERY sink node the device spawns, which is what you want
              for a headset or an interface with one output. Give an attrset instead —
              `{ priority = 1450; profile = "HiFi: Speaker: sink"; }` — to aim at ONE of several,
              and read `profile`'s own description before declaring a bare integer for an internal
              codec: a card with speakers and three HDMI outputs has four sinks, and one number for
              all four is not a tie-break, it is the loss of a ranking that already worked.

              A tie-breaker for an unopinionated app's default-sink pick, never a route: see this
              file's header: the moment any app or a human pins a sink explicitly, that live choice wins over
              this regardless of the number here. Note that a human's pin is REMEMBERED across
              sessions by WirePlumber's own state file, and a remembered pin outranks any number
              declared here; `restoreDefaultTargets` is where that interaction is described.

              Must be a positive integer (`>= 1`).
            '';
          };

          source = lib.mkOption {
            type = priorityType;
            default = null;
            example = 2000;
            description = ''
              `priority.session` this device's SOURCE (capture) node should carry. Same tie-breaker
              semantics, number space and bare-integer/attrset shape as `sink` above, but set
              independently — see this file's header for why one device's best output and best input
              are not always the same unit.
            '';
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          hyperx.sink = 2000;    # outrank the Shure interface's tied 1109 for playback
          shure.source = 2200;   # but let the Shure interface still win the microphone
        }
      '';
      description = ''
        Default-sink / default-source priority overrides, by the same stable device NAME
        `nixaudio.devices` / the derived `nixusb.devices` entries already use — never a card index,
        a `hw:N` path, or a display name, all of which either change on replug or are exactly what a
        stale WirePlumber state file gets wrong (the live defect this option exists to fix). Sink and
        source are independent fields on the same device, because a device is routinely both with
        opposite rankings — see this file's header for the full rationale and the chosen number
        space.

        A name declared here that no device on this host resolves to (a typo, or a device this host
        does not actually compose) is rejected by an assertion rather than silently doing nothing.
      '';
    };

    namingConfig = lib.mkOption {
      type = lib.types.lines;
      internal = true;
      readOnly = true;
      description = "Generated WirePlumber naming rules, consumed by whichever plane is in use.";
    };

    resolvedDevices = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      internal = true;
      readOnly = true;
      description = ''
        The merged device list (derived-from-nixusb plus explicitly declared), exposed so the fabric
        module and health checks can reason about what this host is expected to publish without
        recomputing the projection.

        Each entry carries `source`: `"usb"` for a device derived from `nixusb.devices` (the fleet's
        single inventory, so the same name is assumed to apply wherever nixusb is composed) or
        `"explicit"` for one declared directly in `nixaudio.devices` on this host only. See
        `nixaudio.fabric.catalogue`, the consumer this distinction exists for.

        Each entry also carries `priority`, a `{ sink; source; }` record -- `nixaudio.priorities`'s
        entry for this device's name if one exists, `{ sink = null; source = null; }` otherwise. This
        is a name-keyed overlay applied after identity is resolved, not a field either `nixusb` or
        `nixaudio.devices` carries directly; see this file's header for why.
      '';
    };
  };

  config = {
    nixaudio.namingConfig = namingConfig;
    nixaudio.resolvedDevices = resolvedDevices;

    assertions = [
      {
        assertion = duplicateNames == [ ];
        message = ''
          nixaudio: more than one audio device resolves to the same name: ${lib.concatStringsSep ", " duplicateNames}

          A name collides either because two nixusb devices tagged "${cfg.usbTag}" share an attribute
          name, or because nixaudio.devices redeclares a device that nixusb already provides. USB
          devices must be declared in exactly one place — tag them in nixusb.devices and let this
          module derive them, rather than restating them here.
        '';
      }
      {
        assertion = unknownPriorityNames == [ ];
        message = ''
          nixaudio: nixaudio.priorities declares a priority for a device name this host does not
          resolve: ${lib.concatStringsSep ", " unknownPriorityNames}

          Priority names live in the same namespace as nixaudio.resolvedDevices' own names -- a
          nixaudio.devices attribute name, or a nixusb.devices entry tagged "${cfg.usbTag}". Check
          for a typo, or that the device is actually composed on this host.
        '';
      }
    ];
  };
}
