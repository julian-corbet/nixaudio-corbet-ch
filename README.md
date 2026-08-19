# nixaudio

`nixaudio` presents the audio of several Linux machines as one small semantic system. Applications
remain ordinary PipeWire clients. [JackTrip](https://github.com/jacktrip/jacktrip) carries real-time
audio between machines. Rust owns the product behavior around both.

## User story

The tray lists every active playback stream and lets the user choose one or more outputs with
`device.output` names:

| Source | Output choices |
|---|---|
| Firefox · video | `local.speakers`, `archlxc.hyperx`, `server.devhome` |
| Music player · album | `local.hyperx`, `server.devhome` |

Each stream also has volume and mute controls. The top level shows the default output, default
microphone, health, and circle membership. PipeWire IDs, JackTrip channels and reconnect mechanics
remain diagnostic details.

## Architecture

```text
application stream
  -> local PipeWire links
  -> JackTrip send channel slice
  -> one multichannel UDP session for that peer
  -> JackTrip receive channel slice
  -> remote PipeWire links
  -> physical or virtual output
```

| Component | Owns | Does not own |
|---|---|---|
| PipeWire + WirePlumber | each host's live devices, streams, ports, mixing and local policy | WAN transport or fleet identity |
| upstream JackTrip 3.0.0 | low-latency multichannel UDP media, jitter buffering and packet redundancy | device discovery, UI or remembered routes |
| `nixaudiod` | semantic IDs, live manifests, peer supervision, channel allocation, PipeWire links, state and D-Bus | audio encoding or a second media graph |
| `nixaudio-tray` | StatusNotifier UI over the daemon API | direct PipeWire or JackTrip control |
| Nix modules | packages, stable node/device identity, circle membership, addresses, ports and units | live routing intent |

There is one direct bidirectional JackTrip process per peer pair, not per stream and not per output.
All outputs owned by the receiving peer occupy deterministic channel slices inside that session.
PipeWire performs the actual n-to-n mixing at both ends.

## Current implementation

| Capability | State |
|---|---|
| Stable local device identity | WirePlumber rules derive semantic names from declared USB or explicit hardware identity |
| Live graph and hotplug | `pw-dump --monitor`, rebuilt into a versioned snapshot and emitted over D-Bus |
| Per-stream n-to-n routing | native `pw-link` links; remembered by application/media intent rather than volatile node ID |
| Local defaults, volume and mute | implemented through `wpctl` |
| Cross-host output discovery | live peer manifests; no evaluation-time guesses or fake sinks |
| Cross-host media | pinned upstream JackTrip 3.0.0 through PipeWire's JACK compatibility layer; proven end to end between two hosts |
| Multiplexing | one asymmetric multichannel connection per peer, with deterministic endpoint slices |
| Per-link transport tuning | period, sample resolution, queue depth and packet redundancy are properties of one peer link, not of the host, because a peer on the same switch and a peer on a hotspot need different answers at the same time. `queue` defaults to `auto`, which lets JackTrip's Regulator size the buffer from the link it observes instead of a fixed tolerance |
| A peer that comes and goes | presence belongs to the PEER, not to a transport process: an endpoint is usable only while its peer answers and a session for it is held. Going away takes three consecutive missed probes, about six seconds, so a control-plane blip is not an outage; coming back takes one answer |
| Routes that outlive an outage | a route is remembered as intent and the intent is never overwritten. While its destination is away the stream plays on something audible here, and it reclaims the destination unprompted when the peer returns. A remembered default output follows the same rule |
| Reaching a peer that moved | the peer's declared addresses are tried until one answers, and the media session follows to that address with the peer's name, endpoints and routes unchanged. One LAN is the only proven ground; roaming, NAT traversal and relaying are not claimed |
| Process supervision | JackTrip workers that died, whose command changed, or whose peer left the configuration are restarted or reaped on every pass; one that refuses to stay up is retried with a growing pause rather than respawned in a loop |
| Health | a single status that can genuinely go red: `error` while the daemon cannot read the PipeWire graph and is therefore serving a snapshot about the past, or while the host has no local devices at all; `degraded` while a peer cannot carry audio. A declared device that is currently plugged into a different host is reported as absent, not as a fault — the same declaration is deliberately made on every host the hardware can roam to |
| Frontend | tray defaults, stream volume/mute, route checkboxes and peer state |
| Remote output level control | not yet; levels remain stream-local in this slice |
| Remote microphone consumption | manifested but not yet exposed as a local capture target |
| Internet authentication/encryption | not yet; the first slice is trusted-LAN only |

## Naming and API

`local.speakers` means an output on this machine; `studio.hyperx` means the HyperX output announced
live by peer `studio`. A stream may target several of them. PipeWire numeric IDs appear in
`nixaudioctl inspect` only for diagnosis.

The session D-Bus service is `ch.corbet.NixAudio2`, object `/ch/corbet/NixAudio2`, API version 2.

| Method | Meaning |
|---|---|
| `Inspect()` | complete semantic snapshot as JSON |
| `Route(stream, outputs[])` | replace one stream's explicit target set |
| `ClearRoute(stream)` | make the stream follow nixaudio's default output |
| `SetDefaultOutput(endpoint)` | remember the default output, local or remote |
| `SetDefaultInput(endpoint)` | remember the local default microphone |
| `SetVolume(object, value)` | set local stream or endpoint volume from `0.0` through `1.5` |
| `SetMuted(object, bool)` | set local stream or endpoint mute |
| `Changed(revision)` | notify clients after a semantic graph change |

Pinning a stream to a peer that is currently asleep is legal, and deliberately so: a route the user
set is intent, and intent that could not outlive an outage would be a live link with a longer name.

```bash
nixaudioctl inspect
nixaudioctl default-output archlxc.hyperx.analog_stereo
nixaudioctl route stream:123 local.speakers.analog_stereo archlxc.hyperx.analog_stereo
nixaudioctl mute stream:123 on
```

## Declarative use

| Output | Use |
|---|---|
| `nixosModules.nixaudio` | complete NixOS plane |
| `systemManagerModules.nixaudio` | Arch/CachyOS host facts and `/etc` configuration |
| `homeManagerModules.nixaudio` | Arch/CachyOS user daemon and tray |
| `packages.<system>.nixaudio` | Rust daemon, CLI and tray |
| `packages.<system>.jacktrip` | pinned upstream JackTrip 3.0.0 |

```nix
{
  nixaudio = {
    daemon.user = "alice"; # NixOS only
    tray.enable = true;

    fabric = {
      enable = true;
      node = "laptop";
      control.listen = "192.168.1.10";
      peers.studio = {
        addresses = [ "192.168.1.20" ];
        audioPort = 26301;
      };
    };
  };
}
```

`control.port` defaults to 26300. `audioPort` has no default and belongs to the unordered peer
PAIR: both ends declare the same number, and each host gives every peer a distinct one, which is
what allows one independently supervised JackTrip process per peer. `transport.period`,
`bitResolution`, `queue` and `redundancy` may be set host-wide and overridden per peer.

An Arch host composes the system-manager and Home Manager planes. The system plane writes
`/etc/nixaudio/config.json`; Home Manager points its user service at it:

```nix
nixaudio.daemon.externalConfigPath = "/etc/nixaudio/config.json";
```

Every plane runs JackTrip under nixpkgs' own `pw-jack`, including on a foreign distribution. The
shim exists only to redirect a `libjack.so.0` lookup, so it has to match the binary it redirects:
this JackTrip is Nix-built and its RUNPATH names Nix's libjack2. A distribution that installs
PipeWire's libjack into `/usr/lib` as the system-wide replacement for jack2 ships a `pw-jack` with
its `LD_LIBRARY_PATH` line commented out — correct for its own binaries, a no-op for ours. This is
not a second sound server: `pw-jack` ships no daemon, and libjack speaks the PipeWire protocol to
whichever PipeWire already holds the session socket — the distribution's. JackTrip itself remains an
upstream source build pinned by hash; it is not vendored or forked.

## Security boundary

The control manifest protocol and classic JackTrip P2P UDP media are currently unauthenticated and
unencrypted. Bind and firewall them to a trusted LAN: control is one TCP port per host on an address
the deployment names, and media is one UDP port per peer pair.

Keep those ports below the kernel's default ephemeral floor of 32768 — 26300 upward in the reference
deployment. A port inside that range is one the kernel may hand to any process that asks for "any
port", and if it does so before the daemon binds, the host silently drops out of its circle.

The next transport milestone is pairing plus authenticated, encrypted sessions; it must preserve the
semantic API and can replace the connection adapter without replacing the UI or local PipeWire
graph.

## Verification

Build and test on a suitable build host:

```bash
nix flake check
nix build .#nixaudio
nix build .#jacktrip
```

`experiments/two-node-smoke.sh` is the privileged live-media acceptance test. It gives two real
JackTrip processes separate Linux network namespaces, routes a generated tone through a non-first
channel, records the opposite PipeWire port, and fails on silence. Run it on a disposable build
host with a logged-in PipeWire session; its required tools are listed and checked by the script.

The nixaudio Rust code is MIT. The pinned JackTrip build remains under its upstream mixed-license
terms; its own `--version` output identifies the build as LGPL and points to upstream `LICENSE.md`
for the MIT/GPL portions.
