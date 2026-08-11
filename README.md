# nixaudio

**Audio as one declared fleet-wide fact: stable device names drawn from the shared USB inventory,
and a many-to-many cross-host device pool addressed by name rather than by address.**

Status: **composed and running on all three hosts of the reference fleet, symmetric in production.**
The device-naming layer, the fabric policy, the stable-name catalogue, the packaged daemon, the
local guard, the health check, all three planes and the evaluation checks are complete. Every host
mirrors every other host's real devices — including a host with no local hardware of its own (a
pure-software null sink, declared directly via `nixaudio.devices`-adjacent config rather than a
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

**Everything below has been checked against a running graph, and that distinction is not
decoration.** Three of this module's features — the priority overrides, the node naming, and the
mirror deprioritisation — evaluated cleanly, rendered exactly the text they were meant to render,
were asserted on by green checks, and did nothing whatsoever on every host that ever ran them. A
WirePlumber rule that matches no object is not an error; it is just a rule that matches nothing, and
it logs nothing to say so. Each is described below with the mechanism that makes it work and the
measurement that proves it does, because in all three cases the shape that looks obvious is the
shape that fails silently. A fourth, the fabric's own health probe, spent nine days reporting a
failure that was its own, and a fifth — two planes writing the same file — broke the fabric's TCP
listener on every single boot of two hosts, from long before anyone looked. Those are described
where they belong too.

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

The device rule matches on vendor + product id, narrowed by a `device.bus-id` regex only where a
serial must disambiguate two units of one model. A check asserts the unstable properties never
appear in a matcher.

**A model that publishes no per-unit serial cannot be disambiguated at all, at any level, and this
module does not pretend otherwise.** Measured on a USB audio interface whose `device.serial` reads
as manufacturer plus product and nothing else: there is no property on that device — and therefore
none on any node beneath it — that separates it from a second unit of the same model plugged into
the same host. Vendor and product id are identical by definition, the bus-id carries the same
string with no serial in it, and the only remaining discriminator is the physical port, which is
precisely the unstable property this whole scheme exists to avoid pinning. Two of that model on one
host is a case with no correct answer here. One of them is fine, and that is the boundary.

### The identity is on the device; the number has to land on a node

A device and the nodes it spawns are two different objects with two different property sets, and
`monitor.alsa.rules` is evaluated separately against each. Everything in the table above is a
property of the DEVICE: PipeWire's udev layer writes `device.vendor.id`, `device.product.id` and
`device.bus-id` there and nowhere else. `media.class` is `Audio/Sink` or `Audio/Source` on the
NODES; the device object carries `Audio/Device` and never matches either.

So a matcher listing both — hardware identity AND `media.class`, which is the obvious way to write
"the sink of that headset", and is what this module used to generate — describes an object that does
not exist. It matched the device never, because a device has no `media.class`, and the nodes never,
because a node has no identity keys. **`nixaudio.priorities` therefore never worked on any host, for
the entire life of the option**, in either direction, and nothing said so. It rendered into the
file, the file parsed, the log was clean, and the two devices the option was written to separate —
a USB headset and a USB studio interface — stayed tied at WirePlumber's own ALSA-monitor default of
1109, the exact defect the module exists to break.

That was reproduced as a control rather than inferred: the shipped matcher scored zero hits in the
same file and the same restart in which a `media.class`-only control rule hit every sink on the host.

**What bridges the two objects is a carrier property.** WirePlumber's ALSA monitor copies device
properties onto each node it creates, but by a PREFIX FILTER rather than a fixed key list — every
key beginning `alsa.` or `api.alsa.card.` — and it does so *before* the node rule pass. Upstream put
that loop there for exactly this purpose. So the device rule keeps the hardware matcher unchanged,
still pinned to vendor/product/bus-id and still never to a name, and additionally mints one
synthetic label:

    alsa.nixaudio.device = "hyperx"

which rides the copy onto every node of that card. The node rules then match that label together
with `media.class` — both of them properties a node actually has. The identity matcher is not
weakened; a label derived from it is simply carried somewhere the first matcher cannot reach.

Proven by negative control as well as positive: an otherwise identical carrier minted under a
namespace that is not `alsa.` reaches no node at all. Measured after the fix, on real hardware and
independently per direction — the headset's sink moved 1109 → 1200 while the interface's source
moved 2100 → 2200 — and it works on an internal PCI/DSP card as well as on USB.

### `node.nick` was inert too, and USB hid it

Naming had the same defect, masked by an upstream fallback. `node.nick` used to be set in the device
rule, where it lands on the device object — and `node.nick` is matched by neither half of the copy
filter, so the declared name never reached a single node. What made it look like it worked is that
`alsa.lua` substitutes `device.nick` whenever a node's own `alsa.name` is the literal string
`USB Audio`, which every USB audio-class card reports and no PCI card does. The devices this module
was developed against were USB, so the fallback did the work and the rule took the credit.

Measured on an internal Intel DSP card with `device.nick` set correctly, the six nodes were named
Speaker / HDMI 1 / HDMI 2 / HDMI 3 / Stereo Microphone / Digital Microphone: the declared name
reached none of them. It is now set from a node rule matching the carrier, so the declared name is
authoritative on every card type rather than only on the ones that happen to report `USB Audio`.

### One card, several sinks

Carrier plus `media.class` describes "every sink of this device", which is exactly right for a
headset and wrong for an internal codec. Measured on one: a single unnarrowed rule flattened four
sinks whose distinct 1000 / 696 / 680 / 664 ranking is the only thing keeping an unplugged HDMI
output from being as eligible to become the default as the speakers.

So `nixaudio.priorities.<name>.sink` takes either a bare integer — the common case, one device with
one output — or an attrset that narrows:

```nix
nixaudio.priorities.internal.sink = { priority = 1450; profile = "HiFi: Speaker: sink"; };
```

`profile` matches `device.profile.name`, read off the running graph rather than guessed at. It is
deliberately **not** `card.profile.device`, which looks like it would do the same job: that is a
per-card ORDINAL with no stable meaning between cards. Measured on one host, index 0 is an HDMI
output on the internal card and index 3 is the speakers there, while on both USB devices index 3 is
the sink. A number that selects the right node on one card selects an arbitrary one on the next.

### The state file beats every number here

`nixaudio.restoreDefaultTargets` (default `true`, which is WirePlumber's own behaviour) governs
whether a default a human once chose with `wpctl set-default` is remembered across sessions, per
node, in `~/.local/state/wireplumber/default-nodes`.

Measured in both directions, because it is the first thing to check before concluding that a
priority does not work: with restore on, a sink declared at 9000 still lost the default to a sink at
1200 that the state file had pinned; setting it to false moved the default to the 9000 sink in the
same session. **On a machine that has been in use for a while, priorities arbitrate only among nodes
the state file has never seen** — and that can be very few of them.

It stays `true` anyway, because that is what the rest of this module already promises: priorities
are a tie-breaker for an unopinionated app, and *Routing intent is state, not configuration* below
says the live choice wins. A human who moved their default output is the clearest possible
expression of exactly that. Turning it off makes declared priority authoritative instead, at the
price of a `wpctl set-default` no longer surviving a logout — a real preference about how a machine
should behave, so it is a switch and not a default.

### What the carrier does not cover

The carrier is an ALSA mechanism and is claimed for ALSA only. `bluez.lua` has no device-to-node
property copy loop at all, so a carrier minted on a Bluetooth device object would reach nothing.
That path is **untested**, and is recorded as untested rather than assumed to work. It is also
probably unnecessary: Bluetooth nodes carry `api.bluez5.address` natively, so a bluez node rule can
match hardware identity directly with no carrier in between. Nothing here generates such a rule yet.

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

Mirrored peer devices are deprioritised in default-sink selection
(`nixaudio.fabric.mirrorPriority`, 0 by default). This exists because of a live bug: WirePlumber's
default-node picker chose a fabric mirror on one host, and a screen-streaming server, which has no
explicit sink pin and simply follows the default, streamed its audio into the mirror instead of out
to its client.

**Where that number is applied is the difference between working and not.** These mirrors are pulse
tunnels loaded by pipewire-pulse. No WirePlumber monitor ever sees them, so no `monitor.*.rules`
section can match them — and `stream.rules`, which is what this module used to render for them,
governs streams rather than sink nodes. The fragment matched nothing at all: measured live, all nine
fabric nodes on the host carried no `priority.session` whatsoever. The whole `52-nixaudio-fabric.conf`
drop-in was dead weight, its other half an empty `monitor.alsa.rules = [ ]`; that file and the
internal option that generated it are gone. The priority is now passed where the tunnel is created,
in the module's own `sink_properties` / `source_properties`, where it lands — verified with
`pw-dump`.

**The quotes inside that value are load-bearing**, which is worth stating because getting it wrong
fails silently in two different ways. Measured against a live pipewire-pulse rather than assumed:

    sink_properties="a=1 b=2"    both properties parse
    sink_properties=a=1 b=2      only `a` parses; `b` is silently dropped
    sink_properties={a=1 b=2}    nothing parses; the whole value is silently ignored

The daemon used to send the unquoted form, which is why the data-loop pin — the first property in
the string — was the only one that ever took effect, and why the behaviour read as "pactl cannot
carry two properties here" rather than as a quoting bug.

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
an app or a human via `wpctl`/`pw-link`, always wins, and is then remembered across sessions by
WirePlumber's own state file in preference to anything declared here — see *The state file beats
every number here*). Which stream is actually connected to which sink right now is state in the
running PipeWire graph itself, read and written live, never rebuilt — see `modules/fabric.nix`'s
header for the full reasoning.

## Planes

| Host | Import | Projection |
|---|---|---|
| NixOS | `nixosModules.nixaudio` | `services.pipewire.extraConfig`, `/etc`, `systemd.user.services` + a timer |
| Arch / CachyOS, system layer | `systemManagerModules.nixaudio` | `/etc/pipewire/*.conf.d` + `/etc/wireplumber` |
| Arch / CachyOS, user layer | `homeManagerModules.nixaudio` | `~/.config/…`, two `systemd --user` units and a timer |

On Arch the distro's own PipeWire is already running, so the system plane does not install or manage
the daemons — it drops config where they will read it. Enabling the units belongs to `nixarch`'s
`foreignServices`.

The **home-manager plane is not optional** on those hosts: the audio graph is a user-session
concern, and `nixarch`'s reconciler is pacman/AUR convergence only — it has no file-placement or
user-unit primitive, so it cannot put any of this in place. That gap is precisely what produced the
original problem: a daemon and its drop-ins placed by hand on each Arch host, described by no
configuration, left to drift.

Six of the twelve module files are pure and are imported unchanged into all three trees —
`devices`, `dropins`, `fabric`, `catalogue`, `daemon`, `guard`. `backend` is a system concern and is
imported by the two system planes only; `monitor` and `rt` by the NixOS one. Only the projection
differs — note home-manager's units use the capitalised `Unit`/`Service`/`Install` shape, and a
check asserts the home plane really produces that rather than NixOS's flat one, which would silently
yield a broken unit.

### Exactly one plane may write the drop-ins

A host may legitimately compose two of these planes at once: the system one because it reaches every
session on the box, and the home-manager one because it is the only plane with a real
`systemd --user` primitive. Both Arch hosts here do exactly that, and both used to write the same
fragment basenames — one set into `/etc`, one into `~/.config`.

Identical content, so it looked harmless. It is not, because PipeWire does not pick a winner between
its search roots. It MERGES them, and the merge rule depends on the shape of the section:

| section shape | merge across search roots |
|---|---|
| an object (`context.properties`, `wireplumber.settings`) | the later root overrides — harmless |
| an array (`pulse.cmd`, `monitor.alsa.rules`) | **concatenated** — every entry twice |

`pulse.cmd` is an array, and its entry is the fabric's own
`load-module module-native-protocol-tcp listen=… port=…`. So pipewire-pulse ran that command twice
in one process: the first bind succeeded, the second failed, and every start of both hosts logged

    mod.protocol-pulse: bind() failed: Address already in use
    default: can't run command load-module module-native-protocol-tcp: Address already in use

deterministically, at every single startup, for as long as both planes were composed. It was
originally read as fallout from a hung process holding the port; it is not, and it reproduces on a
clean boot of a host that never hung.

Worse, the failed load **leaks its module object**: pipewire-pulse creates and registers the module
before attempting the bind and does not unregister it when the bind fails. Measured — two
`module-native-protocol-tcp` objects with identical arguments, one actual socket. That is why the
condition survived so long unnoticed, and it is why `pactl list modules` is not a valid test that
peers can reach this host (see *Health*).

`nixaudio.dropIns` is the fact that settles it: `"system"` or `"user"`, with each plane defaulting to
its own kind, so a host composing only one plane never has to answer the question. **This cannot be
an eval-time assertion.** The two planes are separate module trees — a NixOS or system-manager
evaluation and a home-manager one — that never see each other's config, so nothing on either side
can know the other exists. So it is a declared fact, and it has to be stated once in a file both
trees import rather than twice: a value stated in two places is a value that will eventually differ
in two places. The runtime backstop, for a host that got the fact wrong anyway, is the health check's
listener assertion.

The daemon's own config file is deliberately *not* subject to `dropIns`. It is not a drop-in and
nothing merges it — whichever plane runs the daemon must place the file that daemon reads, whoever
owns the PipeWire fragments.

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

Vendoring did **not** rewrite it. The debounced reconciler, the loop-guard, the deterministic tunnel
naming and the data-loop pinning came across untouched, and the vendoring patch changed only the
config surface: the peer table, `PORT` and `FABRIC_LOOP`, formerly hardcoded, now come from a
generated JSON file. Vendoring something and rewriting it are two different changes, and mixing them
would make a regression impossible to attribute.

Two things in it have since been changed on purpose, and both because they were wrong rather than
because they were untidy: the tunnel property string (*Isolation and default-sink safety* above),
and the self-heal path (immediately below).

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

### Self-heal restarts one unit, because three restarted nothing in order

Self-heal fires when the local pulse layer stops answering, and it used to name three units:

    systemctl --user restart pipewire pipewire-pulse wireplumber

That asks systemd for three independent restart jobs and throws away the ordering the vendor units
already declare. Both `pipewire-pulse.service` and `wireplumber.service` carry
`BindsTo=pipewire.service` and `After=pipewire.service`, and wireplumber is additionally
`WantedBy=pipewire.service`. Restarting `pipewire.service` **alone** therefore stops the other two
first — the reverse of `After=` — restarts the daemon, and pulls them back up in order: one job,
correct sequence, no overlap. That is what the unit graph is for, and it is what the daemon does now.

**This function caused a total audio outage,** so the change is the fix for an incident and not a
tidy-up. The chain is the next section.

The liveness probe that decides when it fires stays deliberately narrow — "does `pactl info` answer"
— and deliberately is *not* a graph-health check, which is the obvious improvement and the wrong
one. Through the whole outage it answered yes, correctly: pipewire-pulse was perfectly responsive,
it simply had nothing to offer. Deciding what a healthy device set looks like is a predicate that
has to be right about every host in the fleet — on one, the correct steady state is three ALSA
devices for four kernel cards; on another a card is disabled on purpose — and that predicate lives
in `nixaudio.guard`, once, rather than in a second and worse copy here.

## When the session manager comes up with no devices

A laptop on this fabric had no local audio for 1h45m. Not degraded: `pactl list short cards` was
EMPTY while `/proc/asound/cards` listed all four and `aplay -l` worked. The only sinks left were the
fabric's own tunnels, so the default sink silently became a network mirror of another host and the
machine went quiet. Nothing alerted, because nothing was down — pipewire ran, pipewire-pulse answered
every query, wireplumber was `active (running)`. The graph was simply empty.

The chain, reconstructed from the journal and the kernel log rather than guessed:

1. A system-wide btrfs transaction stall put wireplumber into uninterruptible D state, inside its own
   atomic state-file save. This is routine rather than exotic: each orphaned zero-byte
   `~/.local/state/wireplumber/*.<tmp>` file marks one unclean kill, and there were nineteen of them
   spanning about three weeks.
2. `pactl info` stopped answering, so the daemon's self-heal fired — in the three-unit form above.
3. systemd could not kill the old wireplumber. A task in `TASK_UNINTERRUPTIBLE` never reaches signal
   delivery, so SIGKILL was queued twice and ignored; after 40 s systemd gave up, logged
   `Found left-over process ... Ignoring`, and started the new instance anyway.
4. The old instance still owned every `org.freedesktop.ReserveDevice1.AudioN` D-Bus name. The new one
   asked for them, the frozen owner never answered `RequestRelease`, and the acquire transition timed
   out into BUSY. WirePlumber's ALSA monitor calls `createDevice` only for a reservation that reaches
   `acquired` — so it created NONE. Not some: none, which is exactly why the failure was a totally
   empty graph rather than a partial one.
5. Nothing re-checked. WirePlumber builds its ALSA monitor once per process and has no rescan verb,
   and the daemon's liveness probe asks only whether pactl answers — which it did, perfectly, with an
   empty graph.

No systemd setting fixes step 3. SIGKILL is already the final signal, D state ignores it, there is no
option that makes a unit refuse to start while its cgroup is non-empty (that log line is advisory
only), and `TimeoutStopSec=infinity` would turn a degraded stack into an indefinitely wedged one. So
each of the other steps is addressed at its own layer: step 2 by restarting one unit,
step 4 by `nixaudio.guard.reserveDevice`, step 5 by `nixaudio.guard` itself — and that last one is
the one that generalises, because whatever wedges the enumeration next time, a session manager
running with an empty graph is always wrong and is always fixed by restarting it.

### A guard, and not a check

`nixaudio.fabric.healthCheck` probes an invariant and exits non-zero so a scheduler can alert. The
guard deliberately does not stop there, for two reasons specific to this failure rather than general
enthusiasm for automatic repair:

- **Nobody would be told.** nixwatch has no system-manager and no home-manager plane at all, so it
  cannot be scheduled on either Arch host — and those are the two boxes a person actually listens on.
  An alert-only answer would leave the exact host that failed with no coverage.
- **The repair is one restart of one unit, with no state to lose.** WirePlumber's persistent state —
  default nodes, routes, stream properties — lives on disk and is reloaded. The cost of a needless
  restart is a sub-second gap in playback, against a failure whose cost is total silence until a
  human notices. That asymmetry is what makes repairing correct here, and it would not hold for, say,
  a filesystem.

### The predicate is deliberately not an equality

Repair if and only if **PipeWire exposes zero ALSA devices AND the kernel has at least one card with
a PCM.**

The obvious version — "PipeWire's card count should equal the kernel's" — is wrong on every host in
this fleet, and would have the guard restarting wireplumber forever:

- A card with no PCM device at all is dropped by PipeWire's own ALSA plugin permanently
  (`card->ignored`), and one such card exists on two of the three hosts.
- A card can be excluded **on purpose**: one host disables its GPU's HDMI audio function outright
  with `device.disabled = true`, because a container on the same box holds the same kernel device.
  That is correct configuration, and an equality check would read it as damage.
- A profile can legitimately be `off` — an unplugged HDMI output contributes no node, and should not.

Zero-versus-nonzero has none of those failure modes, and it is also exactly what the incident
produced. A partial loss is a different fault, has not been observed, and this guard does not claim
to catch it rather than pretending to with a rule that cannot hold.

The kernel side is counted from `/proc/asound/pcm`, **not** `/proc/asound/cards`, for the first
reason in that list: a card appears in `pcm` only once it has a PCM device, which is the same
condition PipeWire's ALSA plugin uses to decide the card is worth adding at all. Counting `cards`
would include the very cards PipeWire is right to ignore, and turn "correct steady state" into
"repair forever".

### Why it cannot loop

A repair action whose trigger it cannot itself fix is an infinite loop, and this one restarts the
very unit that pulls it in — so the loop is the default rather than a hypothetical. Three things stop
it:

- **A budget.** At most `maxRepairs` (3) restarts per `repairWindow` (an hour), counted in a file
  under `$XDG_RUNTIME_DIR` — tmpfs, so it also resets on logout, which is the right lifetime for
  "have I already tried this in this session". On exhaustion the unit FAILS instead of repairing,
  which is the honest outcome: a graph still empty after several restarts is not losing a race, and
  one failed user unit is more visible than an audio device that dies every few seconds.
- **`try-restart --no-block`.** The guard is `BindsTo=`/`After=` wireplumber, so a blocking restart
  would wait on a job that is waiting on the guard's own unit to stop.
- **Silent exit 0 on every "not my problem" case** — no `/dev/snd`, no kernel card with a PCM, or
  `pw-dump` unable to reach pipewire at all. That last one matters: if PIPEWIRE is down, restarting
  wireplumber fights `pipewire.service`'s own `BindsTo` and achieves nothing, so it is left to the
  unit that owns it.

`settleSeconds` (20 by default) is a readiness contract standing in for a missing one. Neither
WirePlumber nor PipeWire implements `sd_notify`, and there is no "the first ALSA enumeration
finished" signal to wait for, so the only honest thing to wait on is the condition itself — polled
once a second, exited the moment a device appears. Measured settle on the slowest host here is
~2.4 s; the default is many times that because the two errors are not symmetric. Waiting too long
costs a few more seconds of silence in a case that was going to need repair anyway; deciding too
early restarts a session manager that was merely still enumerating.

**Proven live, all four ways round.** Against a healthy graph it is a no-op —
`guard: ok (4 ALSA device(s) for 4 kernel card(s))`. Against an induced deviceless graph it repaired.
With the cause still present it stopped after exactly three attempts and exited 1. With the cause
removed, its restart brought all four cards back.

### Taking WirePlumber out of the reservation handshake

`nixaudio.guard.reserveDevice` defaults to **false**, the opposite of upstream, and it is the one
option here that removes a behaviour some hosts genuinely need.

`org.freedesktop.ReserveDevice1` is the D-Bus protocol by which audio applications ask each other to
hand over an ALSA card, and step 4 above is what it does when the current owner is frozen: the
monitor creates a device only once its reservation reaches `acquired`, the acquire times out into
`busy`, and no device is created for that card at all. That is the mechanism that turned a hung
process into a total blackout, which is why turning it off is a fix and not a workaround.

Upstream ships the same two `disabled` lines this renders, but inside the `mixin.systemwide-session`
profile block — which the default `main` profile does not inherit. So the reservation is active on an
ordinary desktop session, exactly where it did the damage, and disabling it has to be written into
the `main` profile to have any effect at all.

**What it costs, stated plainly:** cooperative handover with another sound server. A host running a
bare JACK server, or PulseAudio proper, or anything else that wants exclusive use of the same card
and speaks this protocol, should leave it ON — the arbitration is doing real work there, and losing
it means two programs opening one card. On a host where WirePlumber is the only participant, the
handshake has nobody to negotiate with and its only remaining effect is this failure mode. Check
rather than assume:

    busctl --user list | grep ReserveDevice1

On the host that failed, wireplumber owned `ReserveDevice1.Audio0` through `Audio3` and was the sole
owner of every one of them: there was nothing to cooperate with.

### Where the guard runs

It is a `systemd --user` oneshot, `WantedBy=wireplumber.service`, so it runs on every wireplumber
start — the moment at which the failure it looks for is created. An optional timer (`interval`, 5 min
by default, smeared by a 30 s randomised delay so a whole fleet does not restart itself in unison)
covers the case the same investigation showed is possible but did not observe: the reservation can be
lost at runtime with no restart at all, and a graph that empties out mid-session has no start event
to hang a check on. The timer is only safe because of `maxRepairs` — a periodic repair with no budget
is a periodic outage the first time the predicate is wrong about a host.

It is projected by the NixOS and home-manager planes and **not** by system-manager, which is the same
split the daemon already follows and for a sharper reason than symmetry: system-manager can write
`/etc/systemd/user/*.service`, but it never reloads the user manager, so a unit written there stays
inert until the next login — and a guard that arms itself after the next reboot is not a guard. The
reservation fragment is config rather than a unit, so it is placed by whichever plane owns the
drop-ins, system-manager included.

On NixOS, set `nixaudio.guard.user`. `systemd.user.services` installs a unit into EVERY user's
manager, and a guard in a stray root session is worse than a stray daemon: it would find no graph,
because root has none, conclude the session is broken, and start restarting a unit belonging to a
session it cannot see. `ConditionUser=` is the fence. On the home-manager plane a user unit belongs
to one user by construction and no condition is needed.

The guard names its tools bare — `pw-dump`, `jq`, `systemctl`, `awk` — and each plane supplies the
PATH that is right for it. This is the anti-shadowing rule above applied to a script instead of a
package: `pw-dump` is a client speaking the native protocol to one specific running daemon, and on an
Arch host that daemon is pacman's, so baking a nixpkgs PipeWire into the probe would point it at a
different build of the client than the server it is interrogating, for no benefit.
`nixaudio.guard.toolPath` states that requirement (`[ "/usr/bin" ]`) where the user manager's
environment cannot be relied on to supply it.

Both diagnostics are flake packages, so the derivation a unit runs is the derivation a human can run
by hand — on any host, including one that has never composed this module:

    nix run github:julian-corbet/nixaudio-corbet-ch#alsa-guard
    nix run github:julian-corbet/nixaudio-corbet-ch#fabric-health

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

### A probe that is not run by the user it reports on

This check asks about a USER's PipeWire graph, and it is very often not run by that user: a scheduler
runs it as root. Bare `pactl` then talks to root's own non-existent session and gets
`Connection refused` for every local query, so the "do we hold a tunnel to this peer" arm silently
evaluated to zero for every peer — which reads as this host holding no tunnels at all, i.e.
permanently unhealthy.

That is measured history, not a hypothetical. On the host where this was first scheduled the check
latched into a DOWN state on its very first run and stayed there for **nine days** with no second
alert, because the alerting wrapper only fires on a transition. It was blind for the entire window in
which the fabric actually broke.

So the probe now locates the session's runtime directory itself — `/run/user/*/pulse/native` — rather
than assuming it is already inside it. One socket means one session and no ambiguity; zero or several
makes it exit loudly and say which, because the failure being fixed is precisely a probe that scores
everything unhealthy in silence. If it still cannot reach the local graph after that, it fails with
the path it tried rather than quietly reporting on nothing.

### The listener must be a socket, not a module object

`pactl list modules` is not a valid test that peers can reach this host, for the leak described under
*Exactly one plane may write the drop-ins*: a failed bind leaves a module object registered and
looking loaded forever, so the count can be two while the number of sockets is one. The probe asks
the kernel instead — `ss -H -ltn` for the exact `address:port` that peers are told to dial, which the
daemon's generated config now publishes so that the advertised address and the asserted address are
one value and not two.

### What it still cannot see

A peer whose own PipeWire has lost every ALSA device answers TCP, answers pulse, and offers zero real
devices — so `real=0`, and this check skips it as healthy. That is the exact shape of the outage
above, and this probe was structurally incapable of catching it.

It is not fixed here, because it cannot be: from across the fabric, "a peer with no cards" and "a
peer whose cards are all legitimately absent right now" are the same observation, and only the peer
itself knows which. That half is fixed on the peer, by `nixaudio.guard`.

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

**The hardest lesson here is what an evaluation check cannot see.** A check that asserts "a priority
rule was rendered" stayed green for the entire life of an option that matched nothing, because the
text was right and the object it described did not exist. So the rules the carrier mechanism depends
on are now checked for the property that was actually wrong, not for their own presence: a rendered
priority block must contain the carrier and `media.class` and must contain NO `device.*` identity
key at all, the carrier must be in the `alsa.` namespace WirePlumber actually copies, and a rendered
`node.nick` block must be a node rule rather than a device one. The `dropIns` checks are the same
idea from the other side — they assert the ABSENCE of a fragment in the plane that does not own it,
since the defect was two present copies rather than one wrong one. What no check of any kind can
reach is whether WirePlumber's copy loop still has that prefix filter in it; that is proven by the
live positive and negative controls described above, and it is the thing to re-run after a
WirePlumber major version.

## License

MIT
