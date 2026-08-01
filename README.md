# nixaudio

**Audio as one declared fleet-wide fact: stable device names drawn from the shared USB inventory,
and a many-to-many cross-host device pool addressed by name rather than by address.**

Status: **early.** The device-naming layer, the fabric policy, the stable-name catalogue, the
packaged daemon, the health check, all three planes and the evaluation checks are complete and
proven. Not yet cut over on any live host — see *Migration* below, which has a breaking consequence
worth reading before you switch.

**Not hypothetical — this is the exact failure this repo was written to remove.** An earlier
deployment of this same pattern, hand-placed rather than declared, showed it happen for real across
three hosts on one fleet: two of the three, call them `host-b` and `host-c`, had each other in their
peer tables and mirrored each other bidirectionally, each watching the other over a live `pactl
subscribe`. But the third, `host-a`, had `host-b` and `host-c` in ITS table and mirrored both of
them; **neither `host-b` nor `host-c` had `host-a` in THEIRS**, because their hardcoded IP tables
were never updated when the third host joined. So `host-a` could *hear* the fleet but nothing could
*hear it* — exactly the failure mode nixnet-derived peers (§ below) exists to remove, and the actual
case that motivated replacing `FABRIC_NODES`, not a hypothetical one.

## The goal

Every player on any host reaches every real output device on any host. Sources may be any node;
sinks live wherever the hardware physically is. A device that moves between machines keeps its name,
so a reference to it does not break when it is unplugged here and plugged in there.

## Why a daemon and not a standard

Re-examined properly rather than inherited, because "there is no turnkey software for this" deserves
checking every couple of years:

| | |
|---|---|
| **AES67** (SMPTE ST 2110-30) | The professional answer, and PipeWire implements it natively. Assumes PTP clock sync and multicast on a managed LAN — does not traverse a routed overlay, does not survive a roaming laptop |
| **ROC** (`module-roc-sink/source`) | Tolerates lossy links, but explicitly point-to-point with **no discovery** |
| **zeroconf-discover** | mDNS/LAN only, manual per-sink publish, and a standing bug that filters sources (microphones) out |
| **Snapcast** | One-to-many broadcast. Wrong shape |
| **Dante** | Industry default, proprietary, no Linux Virtual Soundcard |

The transport primitives are standard and already present. What is missing upstream is the **policy**
mapping "every device, every direction, over whichever path is currently up". That policy is the
daemon — it stays. What it stops doing is carrying things its siblings already own.

## What this refuses to reinvent

Peer addressing is [`nixnet`](https://github.com/julian-corbet/nixnet-corbet-ch)'s. The daemon
previously carried a hardcoded table:

```python
FABRIC_NODES = { "198.51.100.10": "host-b", "198.51.100.14": "host-c" }
```

with two failure modes baked in: a host stays silently absent until someone remembers to add it, and
a roaming laptop is simply dead once the LAN address stops resolving, with no fallback to the
overlay. nixnet already solves exactly that — N candidate transports per peer, health-checked,
hysteresis-damped, one winner published as a name. So peers default to nixnet's peer set and are
addressed **by name**:

```nix
nixaudio.fabric.peers    # defaults to config.nixnet.peers, addressed by published hostname
```

Adding a host to the fleet adds it to the audio pool. There is no second list to keep in sync, and
no way for a host to be present in one and missing from the other.

Device identity is [`nixusb`](https://github.com/julian-corbet/nixusb-corbet-ch)'s. USB devices are
not declared here at all — they are tagged in the shared inventory and derived:

```nix
nixusb.devices.hyperx = {
  vendorId = "03f0"; productId = "06be"; serial = "C1V51706C2";
  description = "HyperX Cloud III S Wireless headset";
  tags = [ "audio" ];          # <- this is what nixaudio picks up
};
```

Neither is a flake input. Both are read defensively (`config.nixusb.devices or { }`), the same idiom
nixwatch uses for nixpush — a host that composes them gets the derived behaviour, a host that does
not still evaluates and states its own devices and peers. This is checked, not assumed: one of the
evaluation checks runs with both siblings absent.

## What is actually stable

Verified live against `pw-dump` on real hardware rather than assumed — this is the part that would
have been wrong if guessed:

| Property | |
|---|---|
| `device.vendor.id` = `0x03f0` | **stable** — note the `0x` prefix; nixusb stores bare hex, so this module translates |
| `device.product.id` = `0x06be` | **stable** |
| `device.bus-id` | **stable**, carries the USB serial |
| `device.serial` | mangled — `<manufacturer>__<product>_<serial>`, *not* the raw serial |
| `api.alsa.path` = `hw:1` | **unstable** — enumeration order |
| `device.bus-path` = `pci-…-usb-0:1.2.4:1.0` | **unstable** — physical port |

Generated rules match on vendor + product id, narrowed by a `device.bus-id` regex only where a
serial must disambiguate two units of one model. A check asserts the unstable properties never
appear in a matcher.

## The listener has no default bind address

```nix
nixaudio.fabric.listen.address = "203.0.113.14";   # required, no default
```

The pulse protocol has **no working authentication** on PipeWire 1.6.x — verified live: a wrong or
empty cookie still gets full read of device topology, the client list and the whole module config.
`auth-anonymous=0` is a no-op. So whoever reaches this socket can enumerate every device and record
from any of them, including a room microphone.

That makes the bind address part of the security boundary, so it is a deliberate choice rather than
an inherited one. `"any"` binds `0.0.0.0` and is only defensible behind a firewall you have actually
verified — note that an interface-scoped rule authorizes *every* peer on that interface, not just
fabric members.

## Isolation and default-sink safety

Fabric tunnels get their own PipeWire data loop, so a stalled remote tunnel wedges only that loop
and leaves `data-loop.0` — where real hardware and local apps are scheduled — untouched.

Mirrored peer devices are deprioritised in default-sink selection. This exists because of a live
bug: WirePlumber's default-node picker chose a fabric mirror on the desktop, and Sunshine, which has
no explicit sink pin and simply follows the default, streamed its audio into the mirror instead of
out to Moonlight.

**Honest limit:** lowering priority settles the race wherever real hardware also exists. It does not
make a mirror *ineligible*. On a host with no real output device the mirror is still the only
candidate and will still be chosen; fixing that case needs an explicit sink pin in the consuming
application, not a priority tweak here.

## The catalogue

`nixaudio.fabric.catalogue` is a stable-name lookup table, so a consumer (`nixremote`, `nixhost`, a
future tray) can ask "what is this fabric device called" without re-deriving the naming convention
this repo owns. `nixremote` needs exactly this today and does not have it: it string-matches
`Tunnel to tcp:<addr>:<port>/<device>` out of a live `pactl list sinks`, a best-effort match that
falls through silently on a stale address — see *Migration* below for why that string is about to
change shape. The catalogue is what replaces the parsing with a lookup.

Keyed by a stable name: a local device's own name (`"hyperx"`), or `"<peer>.<device>"` for a peer's
device as it will appear once mirrored (`"host-c.hyperx"`). Sized for no fixed peer
count — built from `nixaudio.fabric.peers`, an `attrsOf`, so it grows and shrinks with the fleet.

**What it can and cannot know**, because it matters more here than anywhere else in this repo: a
Nix module evaluates on one host with no view of any other host's configuration. This host's own
devices (`nixaudio.resolvedDevices`) are fully known — nothing to infer. A peer's devices are
knowable only for the slice that is provably the same everywhere: devices derived from
`nixusb.devices`, the fleet's single inventory, composed unchanged wherever nixusb is imported — the
same convergence pattern `nixiam.posix` uses for a device-group gid. A peer's own *explicitly*
declared devices (`nixaudio.devices` — a PCI codec, a virtual sink local to that one host) are
genuinely invisible here and are not guessed at; they simply do not appear. Every entry's `known`
field says which case produced it, and every entry is a NAME, never a live fact — it says nothing
about whether the device is plugged in or the peer is reachable. `nixaudio.fabric.healthCheck` and
the daemon's own reconciliation are what know that, continuously, against the real graph.

## Routing intent is state, not configuration

There is deliberately no option here shaped like `nixaudio.fabric.routes.<stream> = "<sink>"`. The
correct destination for a stream is a property of a *live* session — which window got forwarded
where, which peer is reachable, which sink a human is listening on right now — none of which exists
at eval time and all of which can change with no rebuild. Pinning it into a Nix option would need a
rebuild to move your own audio, and would already be stale the moment anyone plugs in a headset.

This estate already drew this line once: `nixiam`'s lldap module manages the identity *server* and
exposes no option for the users/groups/passwords living inside it, because those records are data,
not configuration, and a real deployment lost real data to a declarative bootstrap that overwrote
them. Routing intent is this module's version of that same directory.

What this module owns instead: the **catalogue** (names), the **tunnels** (daemon.nix, so routing
has somewhere to go), **permissions** (`listen.address`, the shared cookie), and **default**
priorities (the mirror-deprioritisation above — a tie-breaker, not a pin; an explicit choice, from
an app or a human via `wpctl`/`pw-link`, always wins). Which stream is actually connected to which
sink right now is state in the running PipeWire graph itself, read and written live, never rebuilt —
see `modules/fabric.nix`'s header for the full reasoning.

## Planes

| Host | Import | Projection |
|---|---|---|
| NixOS | `nixosModules.nixaudio` | `services.pipewire.extraConfig`, `/etc`, `systemd.user.services` |
| Arch / CachyOS, system layer | `systemManagerModules.nixaudio` | `/etc/pipewire/*.conf.d` + `/etc/wireplumber` |
| Arch / CachyOS, user layer | `homeManagerModules.nixaudio` | `~/.config/…` + a `systemd --user` unit |

On Arch the distro's own PipeWire is already running, so the system plane does not install or manage
the daemons — it drops config where they will read it. Enabling the units belongs to `nixarch`'s
`foreignServices`.

The **home-manager plane is not optional** on those hosts: the audio graph is a user-session
concern, and `nixarch`'s reconciler is pacman/AUR convergence only — it has no file-placement or
user-unit primitive, so it cannot put any of this in place. That gap is precisely what produced the
original problem: a daemon and its drop-ins placed by hand on each Arch host, described by no
configuration, left to drift.

The pure modules are imported unchanged into all three trees. Only the projection differs — note
home-manager's units use the capitalised `Unit`/`Service`/`Install` shape, and a check asserts the
home plane really produces that rather than NixOS's flat one, which would silently yield a broken unit.

## Realtime

`nixaudio.rt` writes the scheduling limits. Worth being precise about what was actually wrong on the
machine this came from: the log said

    mod.rt: could not set nice-level to -11: Permission denied

but realtime scheduling was **fine** — `data-loop.0` and `fabric-loop.0` were both `SCHED_RR`
priority 20. What was missing was `RLIMIT_NICE`, which governs only a negative nice value on the
main thread. Real gap, fixed here; not the one the message makes it look like. "Audio crackles" and
"the main thread runs at nice 0" are different problems.

The group is named, never numbered. `nixiam.posix` owns the fleet's uid/gid registry and converges
device groups across machines (`audio` is 403 alongside video 401, render 402, input 404). A module
inventing its own gid would be a second competing claim on one kernel namespace — and where nixiam
is composed, an assertion checks the group is genuinely declared there.

## The daemon

The mirroring daemon lives here now, vendored from the copy that was previously hand-placed at
`~/.local/bin/fabric-sync` on each host — which is exactly how one machine ended up running a script
no configuration described.

Its logic was **not** rewritten. The debounced reconciler, the loop-guard, the deterministic tunnel
naming, the data-loop pinning and the self-heal path are all load-bearing and proven in production;
vendoring it and rewriting it are two different changes, and mixing them would make a regression
impossible to attribute. The patch is +19 lines and touches only the config surface: the hardcoded
`FABRIC_NODES` table, `PORT` and `FABRIC_LOOP` now come from a generated JSON file.

`nixaudio.fabric.daemon.settings` exposes that config as pure data, so a check can assert on it
without import-from-derivation.

## Health

The daemon once logged `alive: watching 1 peer(s), tunnels=0` every 60 seconds for over five hours
and nothing noticed. A daemon that reports its own brokenness to a log nobody reads is not
monitored; it is just polite about failing.

The obvious check would be wrong, though. **`tunnels == 0` is not a fault** — it is the correct
reconciled state whenever no peer offers a real device, which happens legitimately (a peer whose
only audio device is a presence-gated GPU HDMI controller offers nothing with no display attached,
and the loop-guard correctly declines to mirror a mirror). Alerting on it would page constantly and
be muted within a week.

The real invariant is relational: *if a peer is reachable **and** offers at least one real device,
this host must hold a tunnel to it.* That is what `nixaudio.fabric.healthCheck` asserts, naming the
offending peer when it fails. It registers with `nixwatch` when nixwatch is composed — and nixwatch
dispatches to nixpush by name, so alerting comes for free and nixaudio never references nixpush.

## Migration

**Breaking, and worth knowing before cutover.** Addressing peers by name instead of by IP changes
the mirrored sink descriptions from

    Tunnel to tcp:198.51.100.10:4713/<device>
    Tunnel to tcp:host-b:4713/<device>

`nixremote` matches that string literally (`nixremote.forward.<peer>.audio.localAddress`) to decide
which mirrored sink corresponds to a forwarded app's output. Its match is best-effort and falls
through silently rather than failing, so a stale `localAddress` degrades quietly instead of erroring
— which is precisely why it needs saying out loud. Set `localAddress` to the nixnet-published name
when you cut over.

The tunnel module names also change (`fabric_<last-octet>_<hash>` becomes `fabric_<name>_<hash>`).
The reconciler unloads unrecognised tunnels and loads current ones, so cutover is self-correcting,
with a brief re-tunnel.

## Checks

`nix flake check` runs pure evaluation checks — no VM, no host. Both directions are proven: correct
output generated, and rejected inputs actually rejected (a fabric with no peers, a device redeclared
in two inventories).

## License

MIT
