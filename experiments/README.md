# experiments

Measured results that shaped the current design.

| Experiment | Result | Design consequence |
|---|---|---|
| PipeWire property survey | USB vendor/product IDs and bus ID survive replug; `hw:N` and physical bus path do not | stable WirePlumber carrier names |
| JackTrip 3.0 source build | pinned v3.0.0 builds successfully from upstream source in the flake | upstream media engine, no vendoring |
| JackTrip through `pw-jack` | a process appears as ordinary PipeWire ports named `send_N` and `receive_N` | native PipeWire linking; no fake sink layer |
| Asymmetric channel probe | `--sendchannels 3 --receivechannels 5 -D` exposes exactly three send and five receive ports with no auto-links | deterministic multichannel slices per peer |
| Two-node media smoke test | `two-node-smoke.sh` puts complementary JackTrip peers in separate network namespaces, links a 997 Hz source through channel 2, records the remote PipeWire port, and rejects silence | the real PipeWire/UDP media path, including same-port operation on distinct hosts |
| Media between two real machines | a 440 Hz tone routed to a peer's null sink arrives there at −21 dBFS with exactly 880 zero crossings per second | the transport carries audio between machines, not only between network namespaces |
| Peer loss under a scoped packet filter | cutting one peer's control and media path marks it absent after three probes; streams pinned to it fall back to a local output and reclaim the peer once the filter is removed | fallback and reclaim hold outside fixtures, and liveness is a fact about the peer rather than about our process |
| Hub and P2P probe | both modes work; direct P2P permits peer-specific asymmetric channel plans | one P2P process per peer pair for the first slice |
| Real-time scheduling | identical hardware, binary and 128/48000 quantum, equal uptime: a host whose audio threads run `SCHED_OTHER` stands at 1533 xruns against 17 on the `SCHED_FIFO` host, and keeps gaining while the other gains none. The whole graph suffers, not the JackTrip nodes alone, because it is PipeWire itself that has no priority to run at | the deployment plane grants the audio group an `rtprio` login limit: `RLIMIT_RTPRIO` is the only route to realtime scheduling for a `systemd --user` service, which cannot hold `CAP_SYS_NICE` |
| Port range | the kernel hands out 32768–60999 to any process that asks for "any port", and a busy host may hold dozens of sockets drawn from that range | every fabric port sits below the floor, control 26300 and media 26301 upward, because losing that race is silent: JackTrip exits, the pair carries no audio, and nothing in the audio graph says why |

The two machines in the cross-host results share a kernel and a bridge. Nothing about routed paths,
NAT or radio links follows from them.

## Next experiments

| Question | Acceptance signal |
|---|---|
| Roaming | a peer that changes network keeps its identity and reclaims its routes with no user action and no restart |
| NAT traversal and relay | two peers behind different NATs reach each other directly, and fall back to a relay that forwards media it cannot read |
| Packet impairment | recorded loss/jitter thresholds and sane queue/redundancy defaults |
| Remote capture | a peer microphone becomes a selectable semantic source without feedback loops |
| Secure Internet mode | paired peers reject unknown nodes and media/control are confidential across NAT |
