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
| Streams nobody routed | left alone. A stream with no route of its own belongs to PipeWire's local policy, which already places it on the default; nixaudio does not re-assert that every pass, so moving a stream in `pavucontrol`, `wpctl` or a desktop's own settings STAYS moved. The one exception is a remote default, where there is no local sink for `wpctl` to select and linking each unrouted stream to the peer's channel slice is the entire implementation of it |
| Local defaults, volume and mute | implemented through `wpctl` |
| Cross-host output discovery | live peer manifests; no evaluation-time guesses or fake sinks |
| Cross-host media | pinned upstream JackTrip 3.0.0 through PipeWire's JACK compatibility layer; proven end to end between two hosts |
| Multiplexing | one asymmetric multichannel connection per peer, with deterministic endpoint slices. Slices are allocated for EVERY endpoint a peer advertises, routed or not, so the width is a property of what exists rather than of what is in use: a host advertising seven stereo outputs is sent fourteen channels whether or not anything plays. The cost is continuous — measured at 16 Mbit/s outbound on a host with no routes at all — and it is what the datagram budget below has to be reconciled with |
| Per-link transport tuning | period, sample resolution, queue depth and packet redundancy are properties of one peer link, not of the host, because a peer on the same switch and a peer on a hotspot need different answers at the same time. `queue` defaults to `auto`, which lets JackTrip's Regulator size the buffer from the link it observes instead of a fixed tolerance |
| A peer that comes and goes | presence belongs to the PEER, not to a transport process: an endpoint is usable only while its peer answers and a session for it is held. Going away takes three consecutive missed probes, about six seconds, so a control-plane blip is not an outage; coming back takes one answer |
| Routes that outlive an outage | a route is remembered as intent and the intent is never overwritten. While its destination is away the stream plays on something audible here, and it reclaims the destination unprompted when the peer returns. A remembered default output follows the same rule |
| Reaching a peer that moved | the peer's declared addresses are tried until one answers, and the media session follows to that address with the peer's name, endpoints and routes unchanged. One LAN is the only proven ground; roaming, NAT traversal and relaying are not claimed |
| Process supervision | JackTrip workers that died, whose command changed, or whose peer left the configuration are restarted or reaped on every pass; one that refuses to stay up is retried with a growing pause rather than respawned in a loop |
| Health | a single status that can genuinely go red: `error` while the daemon cannot read the PipeWire graph and is therefore serving a snapshot about the past, or while the host has no local devices at all; `degraded` while a peer cannot carry audio. A declared device that is currently plugged into a different host is reported as absent, not as a fault — the same declaration is deliberately made on every host the hardware can roam to |
| Frontend | tray defaults, stream volume/mute, route checkboxes and peer state |
| Remote output level control | not available, and reported as absent rather than guessed. The manifest carries no level or mute, so a peer's endpoint publishes `null` for both instead of a plausible `1.0`, and setting one is refused rather than silently dropped |
| Remote microphone consumption | UNREACHABLE by construction, not merely unexposed. A host publishes its inputs in the manifest and a peer parses them, but session planning allocates channels from outputs only, so no channel ever carries a remote input in either direction. The field is honest about what exists and misleading about what works; closing that is a protocol change, not a UI one |
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
| `systemManagerModules.nixaudio` | system-manager host facts and `/etc` mechanism |
| `homeManagerModules.nixaudio` | Home Manager user daemon and tray mechanism |
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

A foreign-system host composes the system-manager and Home Manager planes with its host hub's
platform backend. The system plane writes `/etc/nixaudio/config.json`; Home Manager points its
user service at it:

```nix
nixaudio.daemon.externalConfigPath = "/etc/nixaudio/config.json";
```

NixAudio publishes the semantic backend contract as read-only `nixaudio.want`; it contains no
package names or binary paths. Its NixOS backend resolves the contract through nixpkgs and NixOS
options. A foreign host hub resolves the same roles into its own packages and command paths without
becoming a NixAudio flake dependency.

The JackTrip transport needs one special projection: it runs under nixpkgs' own `pw-jack` because
the shim has to be ABI-matched to the Nix-built binary it redirects. This is not a second sound
server: `pw-jack` ships no daemon, and libjack speaks the PipeWire protocol to whichever PipeWire
already holds the session socket. The active platform backend owns that command, alongside the
package decision that makes it correct.

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

## Transport decisions, and what would reopen them

These are written down because each one gets re-argued otherwise, and because the reasoning is
easier to check than to reconstruct.

### Upstream JackTrip carries the media, and nixaudio does not

nixaudio moves no audio. It reads the PipeWire graph, links ports, and supervises one JackTrip
process per peer pair. The hard part of a media engine is the jitter buffer, and JackTrip's
`Regulator` is roughly 1600 lines carrying several years of anti-oscillation work, each patch of
which exists because a simpler version oscillated. Writing that again is the whole job rather than a
detail of it.

Reopen it if: latency measured on a real roaming path is dominated by something the Regulator does
and cannot be configured out of. Note one known limitation — its headroom grows to absorb a rough
patch and has no decrement in the running loop, so a session that survives a bad minute keeps that
latency for the life of the process.

### Not roc-toolkit, despite it being the better loss mechanism

`roc-toolkit` (MPL-2.0, packaged in nixpkgs and Arch) is RTP plus real forward error correction:
Reed-Solomon per RFC 6865 and LDPC-Staircase per RFC 6816, both FECFRAME over UDP. That genuinely
RECOVERS lost packets, where JackTrip's Regulator only CONCEALS loss by inventing plausible audio.
On a lossy path ROC is the better mechanism and this is not a criticism of it.

It loses on fit, not on quality:

- It is a media engine, so adopting it means REPLACING JackTrip rather than adding to it — trading a
  tuned jitter buffer for an untuned one to solve a problem this deployment has not yet measured.
- It does not deliver what is actually missing. Its public API mentions no encryption, no SRTP and
  no DTLS, and it does no NAT traversal or peer identity. The connection adapter is still required
  afterwards, so this is additive work rather than alternative work.
- FEC costs bytes. Repair packets make the datagram budget tighter at exactly the point where the
  budget is already the binding constraint (see below).

Reopen it if: measurement from outside the LAN shows LOSS, rather than latency or clock drift, is
the dominant impairment. That measurement does not exist — the two always-on hosts share a kernel
and a clock, so nothing observed between them says anything about a real Internet path.

Do NOT reopen the variant where nixaudio carries both engines and switches between them by
condition. Two media engines is two jitter buffers to tune, and a switch mid-session is itself an
audible discontinuity — a failure mode added in order to avoid one.

### The datagram budget is the binding constraint

A JackTrip datagram is `redundancy x (16 + period x bytes x channels)` — the header is repeated per
redundant copy, not amortised across them (`UdpDataProtocol.cpp:558` and `:692` in v3.0.0). At the
default 128 frames and 16 bits that is 4 channels at redundancy 1 before a ~1140 byte QUIC datagram
is exceeded, and 2 channels at redundancy 2.

This does not bite today because classic JackTrip is plain UDP, which IP-fragments on a LAN. It
binds the moment media rides a QUIC datagram, which cannot fragment. Any transport proposal has to
answer this before it answers anything else.

### Opus does not shorten the road

Measured against the library rather than assumed: in custom (low-latency) mode the encoder refuses
more than 2 channels at every frame size, `OPUS_SET_INBAND_FEC` returns `OPUS_UNIMPLEMENTED`, and on
the standard path at 2.5 ms and 5 ms frames no in-band FEC is emitted at all. Decoder-side packet
loss concealment does work.

So Opus offers concealment, which the Regulator already has, and neither the multichannel nor the
FEC property that would have justified the change.

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
