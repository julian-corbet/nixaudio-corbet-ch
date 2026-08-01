"""Behavioural check: a RUNNING daemon's peer set must track its config file.

THE BUG THIS IS FOR
-------------------
The daemon read its config exactly once, at module import, and never again. Its peer table was
therefore frozen at whatever the config said the moment the process started. That is a silent,
open-ended failure on any host where the unit outlives a config change:

  - a switch rewrites the generated config to add a peer,
  - nothing restarts the unit -- NixOS's switch-to-configuration does not restart running
    `systemd.user.services`, and the unit file itself is unchanged anyway (only the /etc file it
    points at changed),
  - so the daemon keeps mirroring the OLD peer set, indefinitely, while reporting itself healthy.

Observed in production: a daemon ran for twelve hours on a one-peer table that had been corrected
two generations earlier, heartbeating `watching 1 peer(s)` the whole time. The added peer never
joined, and nothing anywhere said so -- `systemctl status` showed active/running, the on-disk config
was correct, and the two simply disagreed.

WHY THIS IS TESTED THROUGH `fabric_peers()` RATHER THAN A NEW ACCESSOR
---------------------------------------------------------------------
`fabric_peers()` is the daemon's real discovery entry point -- the function the main loop calls to
decide which peers to watch. Asserting on it tests the behaviour that actually matters (does
discovery see the current peer set) rather than the presence of whatever helper the fix happened to
introduce. Against the pre-fix daemon, phase 2 below fails on the real defect: the file gained a
peer, discovery did not.

The peers are loopback addresses backed by one real listener, so the reachability probe inside
`fabric_peers()` runs for real rather than being stubbed out. 127.0.0.2/127.0.0.3 are used rather
than 127.0.0.1 precisely because the daemon skips any peer whose address is one of the host's own --
127.0.0.1 is, and would be skipped; the rest of 127/8 is reachable but not locally assigned.
"""
import importlib.machinery
import importlib.util
import json
import os
import socket
import sys

DAEMON = os.environ["FABRIC_SYNC"]
PORT = 47130
CFG = os.path.abspath("fabric.json")

PEER_A = {"127.0.0.2": "peer-a"}
PEER_B = {"127.0.0.3": "peer-b"}
BOTH = {**PEER_A, **PEER_B}

failures = []


def write_cfg(peers):
    with open(CFG, "w") as f:
        json.dump({"port": PORT, "loop": "fabric-loop.0", "peers": peers}, f)


def write_garbage():
    with open(CFG, "w") as f:
        f.write("{ this is not json")


def check(name, got, want):
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n         got  {got}\n         want {want}")
        failures.append(name)


# One listener answering on every loopback address, so the probe inside fabric_peers() is a real
# TCP connect. Never accepted from -- the probe only connects and closes, which the backlog serves.
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", PORT))
srv.listen(64)

write_cfg(PEER_A)
os.environ["NIXAUDIO_FABRIC_CONFIG"] = CFG

loader = importlib.machinery.SourceFileLoader("fabric_sync", DAEMON)
spec = importlib.util.spec_from_loader("fabric_sync", loader)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def discovered():
    found, ok = mod.fabric_peers()
    if not ok:
        failures.append("fabric_peers() reported failure")
    return found


# Phase 1 -- the starting state. Passes before and after the fix; establishes that the fixture's
# probe actually works, so a phase-2 failure means "did not re-read", not "nothing is reachable".
check("the peer present at startup is discovered", discovered(), PEER_A)

# Phase 2 -- THE REGRESSION. The config gains a peer while the daemon runs. Fails against the
# pre-fix daemon, which holds the import-time table.
write_cfg(BOTH)
check("a peer ADDED to the config while running joins discovery", discovered(), BOTH)

# Phase 3 -- the other direction. A peer removed from the config must leave, or a decommissioned
# host keeps its tunnels until someone notices.
write_cfg(PEER_B)
check("a peer REMOVED from the config while running leaves discovery", discovered(), PEER_B)

# Phase 4 -- re-reading must not make the daemon fragile. An unreadable or half-written config
# (a switch mid-swap, a truncated file) must leave the last known-good table standing rather than
# collapsing the peer set to empty, which would unload every tunnel on the host.
write_garbage()
check("an unreadable config keeps the last known-good peers", discovered(), PEER_B)

# ...and recovery: once the file is valid again, the new value applies with no restart.
write_cfg(BOTH)
check("a config that becomes valid again is picked up", discovered(), BOTH)

if failures:
    print(f"\nfabric-sync daemon checks FAILED: {len(failures)}", file=sys.stderr)
    sys.exit(1)
print("\nfabric-sync daemon: all checks passed")
