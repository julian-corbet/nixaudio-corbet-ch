# nixaudio.fabric.catalogue — the stable-name lookup table a CONSUMER reads instead of re-deriving
# the fabric's naming convention.
#
# ── WHO THIS IS FOR ──────────────────────────────────────────────────────────────────────────────
#
# nixremote already needs to answer "which sink, right here, corresponds to that forwarded window's
# caller" — and today it does that by hand: string-matching `Tunnel to tcp:<addr>:<port>/<device>`
# out of `pactl list sinks` (nixremote's `home/forward.nix`, the `localAddress` option). That match
# is deliberately best-effort and falls through silently on a stale address — nixaudio's own README
# already flags that this breaks the day peers are addressed by name instead of by raw IP, which is
# precisely the migration this repo makes. Without a shared naming surface, every future consumer
# (nixhost, a tray) re-derives the same string surgery a third and fourth time, each one a fresh
# place for the naming convention to drift out from under its callers. This option is that surface:
# a name a consumer can look up, rather than a string it has to parse back out of a live tunnel.
#
# ── WHAT IS ACTUALLY KNOWABLE HERE, AND WHAT IS NOT ─────────────────────────────────────────────
#
# This is an ordinary NixOS/system-manager/home-manager module. It evaluates once, on ONE host, with
# no network access and no view of any other host's configuration tree — that is true of every
# module in this family, not a limitation particular to nixaudio (it is exactly why peer addressing
# is nixnet's problem and device identity is nixusb's: neither can be conjured from one host's own
# eval either). So this catalogue can state two different kinds of fact, and it is careful never to
# blur them:
#
#   THIS HOST'S OWN devices (`cfg.resolvedDevices`)     — fully known. It is this host's own
#                                                          declared config; there is nothing to infer.
#
#   A PEER's devices, as they will appear ONCE MIRRORED — knowable ONLY for the slice of a peer's
#                                                          catalogue that is provably the same
#                                                          everywhere: devices with `source == "usb"`,
#                                                          because nixusb.devices is (per nixaudio's
#                                                          own README) "the fleet's single USB
#                                                          inventory" — one declaration, composed
#                                                          unchanged wherever nixusb is imported, the
#                                                          same convergence pattern nixiam.posix uses
#                                                          to keep a gid identical fleet-wide. A
#                                                          peer's `source == "explicit"` devices (an
#                                                          internal PCI codec, a virtual sink declared
#                                                          directly in ITS `nixaudio.devices`) are
#                                                          genuinely invisible here: reading them would
#                                                          need either a flake input on that peer's own
#                                                          config — the exact coupling this family's
#                                                          defensive-read idiom exists to avoid, and
#                                                          flake.nix already refuses for nixusb/nixnet
#                                                          themselves — or a live query, which is the
#                                                          DAEMON's job (it actually dials the peer),
#                                                          not a pure evaluation's. So they are simply
#                                                          absent from this catalogue rather than
#                                                          guessed at.
#
# Every entry below is tagged with which of those two cases produced it (`known`), so a consumer can
# tell "this host said so directly" from "assumed, because the fleet inventory says so, unverified
# against that particular peer" without having to know this module's internals to make that call.
#
# ── WHAT "KNOWN AT EVAL TIME" DOES NOT MEAN ─────────────────────────────────────────────────────
#
# It does not mean presence, and it does not mean reachability. A catalogue entry existing means
# "this name, if ever mirrored, will look like this" — never "this device is plugged in right now"
# and never "this peer is currently up". Both of those are exactly what `nixaudio.fabric.healthCheck`
# and the daemon's own reconciliation own, continuously, against the REAL graph (see modules/
# monitor.nix's own header on why `tunnels == 0` is not itself a fault). A catalogue entry with no
# matching live tunnel is not a defect in the catalogue; a REAL peer offering a real device with no
# tunnel to it is. Read this option to learn a NAME to look for; read `pactl`/`wpctl`, or the health
# check, to learn whether that name currently resolves to anything.
{ lib, config, ... }:
let
  cfg = config.nixaudio;

  # The fleet-shared vocabulary: this host's own USB-derived device names, which is also the best
  # available guess at what a PEER offers, because that peer is expected to have composed the SAME
  # nixusb.devices inventory (see header). Explicit (non-USB) devices are deliberately excluded —
  # projecting THIS host's own PCI codec onto every peer would claim hardware that almost certainly
  # is not there.
  usbDeviceNames = map (d: d.name) (builtins.filter (d: d.source == "usb") cfg.resolvedDevices);

  localEntries = lib.listToAttrs (map
    (device: lib.nameValuePair device.name {
      origin = "local";
      peer = null;
      device = device.name;
      description = device.description;
      known = "declared";
    })
    cfg.resolvedDevices);

  # One entry per (peer, fleet-shared USB device) pair. `<peer>.<device>` mirrors the same pairing
  # the daemon's own tunnel description already carries (a mirrored sink's label is stamped
  # "<peer-name> <device description>" — see daemon/fabric-sync's `label`), but as a name a consumer
  # can look up BEFORE any tunnel exists, rather than a string parsed back out of one afterwards.
  peerEntries = lib.listToAttrs (lib.flatten (lib.mapAttrsToList
    (peerName: _:
      map
        (deviceName: lib.nameValuePair "${peerName}.${deviceName}" {
          origin = "peer";
          peer = peerName;
          device = deviceName;
          # Not this host's to know: the description string is stamped by the PEER's own
          # nixaudio.devices config (device.description in its generated namingConfig), which this
          # host's evaluation never sees.
          description = null;
          known = "fleet-shared";
        })
        usbDeviceNames)
    cfg.fabric.peers));

  catalogue = localEntries // peerEntries;

  # A local device name colliding with a "<peer>.<device>" key would silently drop one entry from
  # the `//` merge above with no error -- exactly the kind of silent naming collision this module
  # exists to prevent elsewhere. Cheap to catch: the merged key count must equal the sum of both
  # sides' key counts, or something was overwritten.
  keyCollision =
    (builtins.length (lib.attrNames localEntries) + builtins.length (lib.attrNames peerEntries))
    != builtins.length (lib.attrNames catalogue);
in
{
  options.nixaudio.fabric.catalogue = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        origin = lib.mkOption {
          type = lib.types.enum [ "local" "peer" ];
          description = ''
            "local" -- this host's own device, from `nixaudio.resolvedDevices`.
            "peer"  -- a peer's device, as it is expected to appear once mirrored here.
          '';
        };

        peer = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          description = ''
            The peer name (a key of `nixaudio.fabric.peers`) this entry belongs to, or `null` for a
            local entry.
          '';
        };

        device = lib.mkOption {
          type = lib.types.str;
          description = ''
            The stable device name, exactly as chosen by `nixaudio.devices` / the derived
            `nixusb.devices` entry -- never a PipeWire node name or an `hw:N` index.
          '';
        };

        description = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          description = ''
            Human-readable description. Known for a local entry (this host's own
            `nixaudio.devices`/`nixusb.devices` declaration says so). Always `null` for a peer entry
            — that string is stamped by the PEER's own config, which this host's evaluation cannot
            see; read it live once a tunnel exists, from the mirrored sink's own description.
          '';
        };

        known = lib.mkOption {
          type = lib.types.enum [ "declared" "fleet-shared" ];
          description = ''
            How this entry came to be listed here -- NOT whether the device currently exists:

              "declared"     -- this host's own configuration states this device directly.
              "fleet-shared" -- assumed to exist on the named peer because `nixusb.devices` is (by
                                 convention) composed identically fleet-wide, exactly as
                                 `nixiam.posix` converges a device-group gid; NOT verified against
                                 that peer's actual configuration, which this evaluation never reads.

            Neither value says anything about whether the device is plugged in, whether the peer is
            reachable, or whether a tunnel currently exists for it -- see
            `nixaudio.fabric.healthCheck` and live `pactl`/`wpctl` for that. A peer's own
            `nixaudio.devices`-declared (non-USB) hardware never appears in this catalogue at all --
            see this module's header for why that is a limit rather than an oversight.
          '';
        };
      };
    });
    readOnly = true;
    default = catalogue;
    description = ''
      Every sink/source name this host can address on the fabric, without re-deriving the naming
      convention or parsing a live `Tunnel to tcp:<addr>:<port>/<device>` description — see this
      module's header for the nixremote migration this exists to unblock.

      Keyed by a stable name: a local device's own name (e.g. `"hyperx"`), or `"<peer>.<device>"`
      for a peer's device as it will appear once mirrored (e.g. `"host-c.hyperx"`). Sized
      for no fixed peer count — it is built from `nixaudio.fabric.peers`, an `attrsOf`, and grows or
      shrinks with the fleet automatically.

      Every entry is a NAME, not a live fact. It says nothing about whether the device is currently
      plugged in, whether its host is reachable, or whether a tunnel for it exists right now — the
      daemon reconciles the real graph continuously and is the only thing that actually knows that;
      this option is not, and does not try to be, authoritative about it. A peer's own
      `nixaudio.devices`-declared (non-USB) hardware is not listed here at all, because no host's
      evaluation can see another host's local declarations — only the fleet-shared `nixusb.devices`
      vocabulary is projected onto peers. See `known` on each entry.
    '';
  };

  config = {
    assertions = [
      {
        assertion = !keyCollision;
        message = ''
          nixaudio.fabric.catalogue: a local device name collides with a "<peer>.<device>" key, so
          one entry silently overwrote the other. Rename the local device (in nixaudio.devices or
          the nixusb.devices entry tagged "${cfg.usbTag}") so it cannot be mistaken for a
          peer-qualified name, or rename the colliding peer.
        '';
      }
    ];
  };
}
