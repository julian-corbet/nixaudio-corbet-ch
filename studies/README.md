# studies

| Topic | Durable conclusion |
|---|---|
| Local graph | PipeWire is the correct per-host graph and policy substrate; replacing it would mean rebuilding Linux audio |
| Media transport | JackTrip already owns the hard real-time UDP, jitter and multichannel work; Rust should supervise it, not clone it |
| Boundary | PipeWire ports exist at both ends of a JackTrip edge. The graph is not “above” JackTrip and JackTrip is not “above” PipeWire |
| Multiplexing | one asymmetric multichannel session per peer pair is enough; streams and sinks are channel slices and PipeWire links |
| Discovery | remote devices are runtime facts announced by their owner, never guesses projected from another host's Nix evaluation |
| Identity | semantic node/device names must survive address failover, replug and PipeWire object-ID churn |
| Liveness | the unit of presence is the PEER, never the transport process. A JackTrip that is still running proves only that a local process exists — its ports outlive the session — so an endpoint counts as usable only while its owner answers and a session for it is held |
| Absence | going away is a claim that needs evidence and coming back is not, so the two thresholds are deliberately asymmetric: several consecutive missed probes to call a peer gone, one answer to have it back. A control-plane blip must not become an audible dropout |
| Intent | a remembered route is intent, resolved to reachable destinations at the instant sound flows. A fallback must never be written back into the intent: the moment it is, it becomes the route and the original can never be reclaimed |
| Tuning | jitter tolerance, period, resolution and redundancy describe a LINK, not a host. A circle holds a peer on the same switch and a peer on a hotspot at the same time, so one host-wide value is wrong for one of them by construction |
| Security | classic direct JackTrip media is not the final Internet trust boundary; secure pairing/transport remains a separate milestone |
