# nixaudio

**Audio as one declared fleet-wide fact: stable device names drawn from the shared USB inventory,
and a many-to-many cross-host device pool addressed by name rather than by address.**

Status: **composed and running on all three hosts of the reference fleet, symmetric in production
(2026-08-02).** The device-naming layer, the fabric policy, the stable-name catalogue, the packaged
daemon, the health check, all three planes and the evaluation checks are complete and proven. Every
host mirrors every other host's real devices — including a host with no local hardware of its own
(a pure-software null sink, declared directly via `nixaudio.devices`-adjacent config rather than a
USB-derived entry) and a host whose devices only exist because a co-resident container's kernel
modules were loaded on its behalf. Before assuming symmetry alone makes a new host's join correct,
read *What deriving from nixnet does and does not guarantee* below — it is still exactly as true
now as when only one host had adopted this. See *Migration* below for the breaking consequence
worth reading before any future switch.

**Not hypothetical — a version of this failure has now happened twice, from two different causes.**
An earlier deployment of this same pattern, hand-placed rather than declared, showed it happen across
three hosts on one fleet: two of the three, call them `host-b` and `host-c`, had each other in their
peer tables and mirrored each other bidirectionally, each watching the other over a live `pactl
subscribe`. But the third, `host-a`, had `host-b` and `host-c` in ITS table and mirrored both of
them; **neither `host-b` nor `host-c` had `host-a` in THEIRS**, because their hardcoded IP tables
were never updated when the third host joined. So `host-a` could *hear* the fleet but nothing could
*hear it* — the actual case that motivated replacing `FABRIC_NODES` with nixnet-derived peers (§
below), not a hypothetical one.

Deriving peers from nixnet removes that specific cause — there is no longer a second, hand-maintained
table to forget. But on the day this module was first composed onto a real host, the same *symptom*
showed up again from a different cause: nixnet's own peer table on that host was itself incomplete —
one fleet machine simply was not a peer there yet — so the fabric peer list derived from it inherited
exactly the same gap, and that machine stayed unreachable. Centralising the peer list did not make the
list complete; it made there be exactly one place to fix instead of two. See *What deriving from
nixnet does and does not guarantee* below for what that promise actually covers, and what it never
did.

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

Adding a host to nixnet's peer table adds it to the audio pool automatically. There is no second list
to hand-maintain — see immediately below for exactly what that guarantee does, and does not, cover.

### What deriving from nixnet does and does not guarantee

The real, worthwhile benefit: there is exactly ONE peer table for the whole audio fabric, not one per
host cross-referencing hand-copied IPs. Fix a host's peer status in nixnet and every consumer of
`config.nixnet.peers` — this module included — picks it up on the next rebuild, with nothing here to
edit or forget.

What it does NOT buy, and what an earlier draft of this README overstated: this module's peer list is
exactly as complete as nixnet's own peer table on THIS host, no more. If a host is missing from
`config.nixnet.peers` — nixnet not composed there, or composed but that peer never actually joined
nixnet's own view of the fleet — nixaudio has no way to know that host should exist. It derives an
empty gap from an empty gap. This is not hypothetical: it is exactly what happened in production the
day this module was first composed onto a real host (see above). Deriving from a single source
doesn't make that source correct; it centralises WHERE correctness has to be maintained, from N
places down to one. That is the actual claim, and it is a real one — "no second list to drift apart
from" is true and useful — but "no way for a host to be silently missing" was not, and this file no
longer says it.

Can eval time catch it? Partly, because two different failure shapes hide behind "a host is missing":

- **A host absent from `nixnet.peers` entirely.** Invisible here, structurally: this module's
  evaluation happens on one host with no knowledge of the fleet beyond what `config.nixnet.peers`
  already says on that host. There is no live network probe at eval time, and even if there were,
  "which hosts SHOULD exist" is not a fact Nix evaluation can derive from nothing. Catching this needs
  a check on nixnet's own side (does its peer table match some independent fleet inventory?), not
  here — a pure function of one host's config cannot audit a list it was only ever given, not asked to
  verify.
- **A host `nixnet.peers` DOES know about, but with no hostname published for it.** This one IS
  visible at eval time: it shows up as an attrset key with `hostnames == [ ]`. Silently filtering it
  out of the derived peer set (which the code already did) would repeat the exact "quietly missing"
  mistake one layer up, so it no longer does that silently — dropping such a peer now raises a
  `nixaudio.fabric` warning naming it, checked in `checks/default.nix`. The existing
  `cfg.peers != { }` assertion still catches the total-loss case (every peer dropped, or none ever
  declared) as a hard failure — see *Isolation and default-sink safety* onward for how the rest of
  this module treats "detectable at eval time" versus "only knowable live" as two different kinds of
  fact throughout, not just here.

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

## The backend

`nixaudio.backend` names the packages the rest of this module is written against. Until it existed,
this module renamed devices it did not install a session manager to enumerate, and hung a TCP
listener off a pulse layer it never asked anyone to install — survivable on NixOS by accident
(`services.pipewire.*` brings the daemons with the policy), and not survivable on a host whose distro
is not NixOS, where the system plane wrote config into `/etc` and assumed somebody had once run the
right `pacman -S` by hand.

The selection is not a menu. There is no host that wants PipeWire without its session manager, or a
fabric listener with no pulse layer to host it — those are broken installs, not configurations. So
one universal set, plus entries gated on a hardware fact nothing can derive:

| entry | why it is in the backend |
|---|---|
| `pipewire` | the sound server |
| `wireplumber` | the session/policy manager. Without it there are no device nodes and no routing, and the naming/priority rules this repo generates are never evaluated |
| `pipewire-pulse` | **mandatory here specifically**: the fabric's own `module-native-protocol-tcp` listener is loaded into it, and the daemon reaches the graph through it |
| `pipewire-alsa` | routes ALSA-native clients into PipeWire instead of letting one seize `hw:` exclusively and lock every other stream out of the card |
| `pipewire-audio` | (Arch) card profiles + the Bluetooth codec set |
| `pipewire-zeroconf` | **not what the fabric runs on** — this module routes its pool over `module-native-protocol-tcp`, and rejects zeroconf as a *transport* on the merits (below). Declared anyway, because the package is also RAOP/AirPlay discovery for third-party network sinks a host did not declare, which is a separate capability from the pool this module manages |
| `alsa-utils` | diagnosis, and backend rather than desktop: `alsamixer` is the only way to see and clear a hardware mute switch PipeWire does not expose, and a muted ALSA control is silence no matter how correct the graph above it is |
| `sof-firmware` | **gated, default off** — `backend.sofFirmware.enable`. Required on Intel DSP audio (`sof-hda-dsp`, `snd_sof_pci_intel_*`), where without it there is no sound at all. See the option's own description for why a host that shares the very same audio devices still does not need it: SOF is Intel-only, a container loads no firmware, and USB audio class devices need none |

Deliberately **not** declared, recorded as data rather than as a comment so a check can enforce it:
`alsa-plugins` (its pulse/jack plugins are what `pipewire-pulse` and PipeWire's JACK layer replace)
and `alsa-firmware` (pre-DSP era cards, unrelated to SOF). Being useless *to the fabric* is not on
that list and never was a reason on its own — see `pipewire-zeroconf` above.

### The plane divide is not a package-name mapping

On Arch the packages *are* the mechanism, so they must be installed. On NixOS there is nothing to
name: `pipewire-pulse`, `pipewire-alsa`, `pipewire-audio`, `pipewire-zeroconf` and
`alsa-card-profiles` do not exist as nixpkgs attributes at all. nixpkgs ships one `pipewire`
derivation carrying the pulse binary, the `alsa-card-profile` profile sets, the `bluez5` plugin and
`libpipewire-module-{zeroconf-discover,raop-discover,raop-sink}.so`, and the options switch on
parts of it —
`alsa.enable` writes `/etc/alsa/conf.d/*` pointing into that same package, `pulse.enable` un-masks
its units. So the table names, per entry, *either* a nixpkgs attribute *or* the NixOS option that
already provides it, never both.

**We do not shadow.** On Arch every package comes from pacman — the distro's copy is first on `PATH`
and is what actually runs, so a second nixpkgs copy of a *sound server* would leave which daemon the
units, the udev rules and the ALSA plugin config point at ambiguous. On NixOS anything an option
provides is never also installed as a package. Both directions are assertions, and checks prove the
assertions are not vacuous.

    # Arch: this module publishes names and installs nothing
    nixarch.packages.pacman = config.nixaudio.backend.archPackages;
    nixarch.packages.aur = config.nixaudio.backend.aurPackages;

`backend.enable` defaults to `fabric.enable`, because the fabric is written against the backend and
cannot work without it; the reverse — a host that wants its audio declared and joins no device pool
— is a supported shape.

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
impossible to attribute. The patch touches only the config surface: the peer table, `PORT` and
`FABRIC_LOOP`, formerly hardcoded, now come from a generated JSON file.

`nixaudio.fabric.daemon.settings` exposes that config as pure data, so a check can assert on it
without import-from-derivation.

### The peer table is re-read, not captured at startup

Reading that file once, at import, was itself a bug — and a quiet one. Nothing restarts this unit
when its config changes: `switch-to-configuration` does not restart running `systemd --user`
services, and across a config-only change the unit file is byte-identical anyway, since only the
`/etc` file it points at moved. So a daemon started before a peer was added kept mirroring the old
peer set indefinitely, while every signal an operator would check said healthy — unit active, config
on disk correct, heartbeat ticking.

That is not hypothetical. One host ran twelve hours on a one-peer table that had been corrected two
generations earlier, heartbeating `watching 1 peer(s)` throughout. What hid it is worth recording:
the missing peer's devices *were* mirrored the whole time, by orphaned tunnels left behind by the
retired hand-deployed daemon, which `module-tunnel-*` keeps reconnecting on its own every 15
seconds. Nothing declarative owned them; the next PipeWire restart would have removed them for good,
and this module would not have recreated them. The fabric looked right and was held together by
garbage.

So discovery reads the file rather than a snapshot of it. A peer added to the config joins on the
next pass and a peer removed leaves, with the existing watcher teardown dropping its tunnels. An
unreadable or half-written config keeps the last known-good table — an empty peer set reads as
"every peer left the fabric" and would unload every tunnel on the host over a transient.

Only the peer table refreshes. `PORT` and `FABRIC_LOOP` stay as read at startup, because every
loaded tunnel carries both baked into its module arguments — applying them live would mean tearing
down and rebuilding every tunnel, and they are also the two values that do not move in practice.

This is the one thing here that cannot be checked by evaluation. "Does a running daemon notice its
config changed" lives entirely in the gap between the generated file and what a long-lived process
holds in memory, so `checks/daemon-peer-reload.py` executes the daemon's real discovery entry point
against a config file rewritten underneath it, with a loopback listener behind the reachability
probe rather than a stub — a stubbed probe can pass while the probe is what is broken.

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
in two inventories, a fabric with its backend switched off, an entry claiming both a nixpkgs
attribute and a NixOS option).

They are also mutation-proven rather than merely green: giving `pipewire` a nixpkgs attribute
alongside its option turns the anti-shadowing check red, dropping `alsa-utils` from the table turns
five red, removing `sof-firmware`'s hardware gate turns four red, declaring one of the two rejected
packages turns three red, pushing `pipewire-zeroconf` back into the rejected list turns four red,
and renaming a gate on either of the two sides that have to agree about it turns twenty-three red.
Each one goes green again on restore.

## License

MIT
