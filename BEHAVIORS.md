# Behaviours

What nixaudio is for. These are goals, not a roadmap. They are fixed: changing one is a decision,
not a refactor. `studies/` records why the architecture follows from them, and `experiments/`
records what was measured.

## The product

Several computers, one audio system. A stream playing on any of them can be sent to a speaker,
headset or microphone attached to any other — quickly enough to feel local, over the open Internet,
with no server in the middle.

This is the capability that low-latency audio services sell as a subscription, built peer to peer
instead, at household scale.

## Fixed goals

| Goal | What it means |
|---|---|
| **Peer to peer** | Media never passes through a server anyone else operates. A relay exists only for peers that cannot reach each other directly, and it forwards ciphertext it cannot read. |
| **Joining is knowing the secret** | Any Internet-connected computer that knows the circle's secret can join it. No accounts, no directory service, no per-device approval step. |
| **Encrypted between peers** | Every byte of media and control between two peers is authenticated and encrypted. The circle secret is what authenticates; it is not itself a media key. |
| **Quick enough to feel local** | The target is conversational and musical use, not playback sync. Latency budget is set by the transport, and a retransmission is worse than a dropped packet. |
| **Reliable** | A control-plane blip must not become an audible dropout. One unreachable peer costs that peer and nothing else. |
| **Household scale** | Up to about a dozen devices in a circle. Design for that number and no more: it makes a full mesh, a shared secret and an in-memory peer table the right answers rather than compromises. |
| **The machines disappear** | Users choose `hyperx` or `speakers` on a named peer. Addresses, PipeWire object IDs and transport channel slices are diagnostics, never the interface. |

## Explicit non-goals

Each of these is a deliberate exclusion, not an omission awaiting a contributor.

- **Video.** A separate product if it is ever built. Nothing here should be bent to accommodate it.
- **Mixing.** One volume per stream and one per device — what the operating system already gives us.
  Per-destination faders are not a goal: they would need a gain stage per route, and anyone who
  wants a mixing desk should run a mixing desk.
- **A hosted service.** No accounts, no web console, no billing, no multi-tenancy, no fleet
  management. A circle is configuration, not a tenant.
- **Being a DAW, or a conferencing application.** nixaudio moves audio between machines. What
  produces or consumes it is somebody else's program.
- **Replacing PipeWire or JackTrip.** See constraints.

## Constraints these goals impose

**Upstream JackTrip does the hard real-time work, and we do not fork it.** It already owns the
low-latency UDP, jitter buffering, packet redundancy and multichannel layout. nixaudio pins an
upstream source build and supervises the process; it does not vendor, port or link its code.

The reason is engineering, not licence. Everything load-bearing in JackTrip is MIT — its GPL surface
is the Qt GUI, which the headless build excludes — so vendoring would be permitted. But its data
protocol calls back into the JackTrip mediator across twenty-one methods, so a faithful lift drags
several thousand lines of Qt-typed C++ along with it and forks the wire format, in exchange for a
chokepoint that is the easy part of the problem. Reading it is free and encouraged; copying it buys
very little and costs a fork forever. There is also no library to link against: upstream builds a
single executable and declares no library target.

**PipeWire owns each host's local graph.** Devices, streams, ports, mixing and local policy are its
job. nixaudio never becomes a second media graph.

**Rust owns the product behaviour.** Semantic identity, peer supervision, channel allocation,
linking, persisted intent and the API.

**The security layer is ours, and it sits outside JackTrip.** Classic JackTrip media is
unauthenticated plaintext UDP. Because we do not fork it, encryption cannot live inside it — it
belongs to the connection adapter nixaudio owns, which must be replaceable without touching the
semantic API, the frontend, or the local PipeWire graph.

## Assumed deployment

A circle is a handful of ordinary computers on ordinary Internet connections, most behind NAT. No
overlay network, VPN or static addressing may be assumed — where one exists it is a convenience for
that operator, never a prerequisite the design leans on.

## Stated future, not a current goal

A native Rust transport, replacing the supervised JackTrip process, is wanted eventually. It is not
scheduled and nothing should be designed around its arrival. The connection adapter boundary above
is what makes it possible later without a rewrite.
