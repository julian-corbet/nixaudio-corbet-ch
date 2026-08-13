# experiments

Measured results that shaped the current design.

| Experiment | Result | Design consequence |
|---|---|---|
| PipeWire property survey | USB vendor/product IDs and bus ID survive replug; `hw:N` and physical bus path do not | stable WirePlumber carrier names |
| JackTrip 3.0 source build | pinned v3.0.0 builds successfully from upstream source in the flake | upstream media engine, no vendoring |
| JackTrip through `pw-jack` | a process appears as ordinary PipeWire ports named `send_N` and `receive_N` | native PipeWire linking; no fake sink layer |
| Asymmetric channel probe | `--sendchannels 3 --receivechannels 5 -D` exposes exactly three send and five receive ports with no auto-links | deterministic multichannel slices per peer |
| Two-node media smoke test | `two-node-smoke.sh` puts complementary JackTrip peers in separate network namespaces, links a 997 Hz source through channel 2, records the remote PipeWire port, and rejects silence | the real PipeWire/UDP media path, including same-port operation on distinct hosts |
| Hub and P2P probe | both modes work; direct P2P permits peer-specific asymmetric channel plans | one P2P process per peer pair for the first slice |

## Next experiments

| Question | Acceptance signal |
|---|---|
| Failover | killing JackTrip or removing the primary address recovers without changing semantic route IDs |
| Packet impairment | recorded loss/jitter thresholds and sane queue/redundancy defaults |
| Remote capture | a peer microphone becomes a selectable semantic source without feedback loops |
| Secure Internet mode | paired peers reject unknown nodes and media/control are confidential across NAT |
