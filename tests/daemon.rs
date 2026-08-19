//! End-to-end tests for `nixaudiod`: a real process, a real session bus, a real `nixaudioctl`,
//! against a fake PipeWire and a fake JackTrip.
//!
//! These exist because the daemon's three binaries had no tests at all, and because nothing in
//! this project had ever run: every claim about it was an argument from the source. A test that
//! starts the actual process and reads the actual argv it produced is the cheapest thing that
//! settles such an argument.

mod support;

use serde_json::json;
use support::{link, manifest, port, sink, stream, FakePeer, World};

/// One sink and one application, which is the smallest world that is still recognisably the
/// product: a named device and something playing into it.
fn one_sink_and_firefox(title: &str) -> serde_json::Value {
    json!([
        sink(10, 100, "alsa_output.usb-hyperx", "hyperx", "analog-stereo"),
        port(11, 10, "playback_FL", "in", "FL"),
        port(12, 10, "playback_FR", "in", "FR"),
        stream(20, 200, "Firefox", title, "Music"),
        port(21, 20, "output_FL", "out", "FL"),
        port(22, 20, "output_FR", "out", "FR"),
    ])
}

/// The first thing that has never happened on any host: the daemon starts, claims its bus name,
/// reads a graph and answers a question about it.
#[test]
fn the_daemon_answers_inspect_with_the_declared_device_name() {
    let world = World::local(one_sink_and_firefox("A useful tab"));
    let snapshot = world.inspect();

    let outputs = snapshot["outputs"].as_array().expect("outputs");
    assert_eq!(outputs.len(), 1, "one declared sink, one endpoint");
    assert_eq!(
        outputs[0]["id"], "local.hyperx.analog-stereo",
        "the endpoint is named from the declared carrier and its profile, not from the ALSA node"
    );
    assert_eq!(outputs[0]["available"], true);

    let streams = snapshot["streams"].as_array().expect("streams");
    assert_eq!(streams.len(), 1);
    assert_eq!(streams[0]["id"], "stream:200", "keyed by object.serial");
    assert_eq!(streams[0]["application"], "Firefox");
    assert_eq!(streams[0]["title"], "A useful tab");
}

/// Sending audio where it is needed, and remembering that you did. One link per channel, matched
/// by channel rather than by position, persisted across a restart of the daemon itself.
#[test]
fn pinning_a_stream_links_every_channel_and_survives_a_restart() {
    let mut world = World::local(one_sink_and_firefox("A useful tab"));

    world
        .ctl(&["route", "stream:200", "local.hyperx.analog-stereo"])
        .expect("route the stream");

    let links = world.until_calls("both channels to be linked", |calls| {
        calls.iter().filter(|c| c.starts_with("pw-link ")).count() >= 2
    });
    let links: Vec<&String> = links.iter().filter(|c| c.starts_with("pw-link ")).collect();
    assert_eq!(
        links,
        ["pw-link 21 11", "pw-link 22 12"],
        "FL to FL and FR to FR, by channel and not by port order"
    );

    let state = world.persisted_state().expect("state was written");
    assert_eq!(
        state["routes"]["firefox|Music"],
        json!(["local.hyperx.analog-stereo"]),
        "the intent is stored against the application and its role"
    );

    world.restart();
    world.until_calls("the route to be re-applied after a restart", |calls| {
        calls
            .iter()
            .filter(|c| c.as_str() == "pw-link 21 11")
            .count()
            >= 2
    });
}

/// A pinned route must not be a one-off: the reconciler re-establishes it whenever the graph
/// moves. This is the difference between "the link was made" and "the stream lives there".
#[test]
fn a_pinned_route_is_restored_when_the_graph_changes_underneath_it() {
    let world = World::local(one_sink_and_firefox("A useful tab"));
    world
        .ctl(&["route", "stream:200", "local.hyperx.analog-stereo"])
        .expect("route the stream");
    world.until_calls("the initial link", |calls| {
        calls.iter().any(|c| c == "pw-link 21 11")
    });

    // The same world, now with the links actually present, and a different track playing. The
    // route must survive the title change and must not be issued a second time.
    let mut graph = one_sink_and_firefox("A different tab");
    graph
        .as_array_mut()
        .unwrap()
        .extend([link(30, 20, 21, 10, 11), link(31, 20, 22, 10, 12)]);
    world.stage(graph);

    let snapshot = world.until("the stream to report its target", |snapshot| {
        snapshot["streams"][0]["targets"]
            .as_array()
            .is_some_and(|targets| !targets.is_empty())
    });
    assert_eq!(
        snapshot["streams"][0]["targets"],
        json!(["local.hyperx.analog-stereo"]),
        "the pinned target survived a change of track"
    );
    assert_eq!(
        snapshot["streams"][0]["explicit_targets"],
        json!(["local.hyperx.analog-stereo"]),
        "and it is still an explicit pin, not an accident of the default output"
    );
}

/// Level control is a local concern by design: nixaudio moves audio, it does not mix. A remote
/// endpoint must refuse rather than silently do nothing.
#[test]
fn setting_a_local_default_reaches_wpctl() {
    let world = World::local(one_sink_and_firefox("A useful tab"));

    world
        .ctl(&["default-output", "local.hyperx.analog-stereo"])
        .expect("set the default output");

    let calls = world.until_calls("wpctl to be asked to set the default", |calls| {
        calls.iter().any(|c| c.starts_with("wpctl set-default"))
    });
    assert!(
        calls.iter().any(|c| c == "wpctl set-default 10"),
        "the sink's PipeWire node id, not its semantic name: {calls:#?}"
    );
}

/// An unknown output is refused rather than accepted and quietly dropped. The tray offers only
/// endpoints the daemon published, so anything else is a bug in the caller and should say so.
#[test]
fn routing_to_an_unknown_output_is_refused() {
    let world = World::local(one_sink_and_firefox("A useful tab"));

    let error = world
        .ctl(&["route", "stream:200", "beta.nonexistent"])
        .expect_err("an unknown output must be refused");

    assert!(
        error.contains("beta.nonexistent"),
        "the error names the output that was not found: {error}"
    );
    assert!(
        world.calls_matching("pw-link").is_empty(),
        "nothing was linked on the way to failing"
    );
}

/// The whole cross-host path, with no host across it: a peer publishes a manifest, and exactly one
/// JackTrip session is started for it, carrying every one of that peer's outputs in one connection.
///
/// This is also the only place the real argument vector is asserted. `experiments/two-node-smoke.sh`
/// hand-writes its own and has already drifted from what the daemon actually passes.
#[test]
fn a_peer_manifest_starts_one_jacktrip_carrying_all_of_its_outputs() {
    let peer = FakePeer::serving(manifest(
        "beta",
        &[
            ("local.hyperx", &["FL", "FR"]),
            ("local.hdmi", &["FL", "FR", "FC", "LFE"]),
        ],
    ));
    let world = World::with_peers(
        one_sink_and_firefox("A useful tab"),
        json!({ "beta": { "addresses": ["127.0.0.1"], "controlPort": peer.port, "audioPort": 46001 } }),
    );

    let calls = world.until_calls("a JackTrip session for beta", |calls| {
        calls.iter().any(|c| c.starts_with("jacktrip "))
    });
    let sessions: Vec<&String> = calls
        .iter()
        .filter(|c| c.starts_with("jacktrip "))
        .collect();
    assert_eq!(
        sessions.len(),
        1,
        "one session per peer pair, not one per output: {sessions:#?}"
    );

    let argv = sessions[0].as_str();
    // beta's two outputs are 2 + 4 channels, all multiplexed into one connection; alpha announces
    // its single stereo sink back. Role falls out of name order alone -- alpha < beta -- which is
    // what "no central server" means in practice.
    for expected in [
        "--server",
        "--sendchannels 6",
        "--receivechannels 2",
        "--bindport 46001",
        "--peerport 46001",
        "--clientname nixaudio-jt-beta",
        "--nojackportsconnect",
        "--udprt",
    ] {
        assert!(
            argv.contains(expected),
            "argv is missing {expected}: {argv}"
        );
    }
    assert!(
        calls
            .iter()
            .any(|c| c == "jacktrip-env PIPEWIRE_LATENCY=128/48000"),
        "the session inherits the period and rate it was configured with: {calls:#?}"
    );

    // The session is running; now it registers its ports, as pw-jack makes a real one do. Only
    // then is the peer reachable -- spawning a process is not the same as carrying audio.
    let mut graph = one_sink_and_firefox("A useful tab");
    graph
        .as_array_mut()
        .unwrap()
        .extend(support::jacktrip_session(50, 500, "beta", 6, 2));
    world.stage(graph);

    let snapshot = world.until("beta to be reported as reachable", |snapshot| {
        snapshot["peers"]
            .as_array()
            .is_some_and(|peers| peers.iter().any(|p| p["available"] == true))
    });
    assert_eq!(snapshot["peers"][0]["name"], "beta");
    assert_eq!(snapshot["health"]["status"], "ok");
    assert!(
        snapshot["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|output| output["id"] == "beta.hyperx"),
        "beta's outputs are offered locally by their semantic names: {}",
        snapshot["outputs"]
    );
}

/// A peer going away is a remote problem and must stay one. Health degrades, the peer is marked
/// unreachable -- and nothing tears up the local graph on the way.
#[test]
fn losing_a_peer_degrades_health_without_disturbing_local_audio() {
    let peer = FakePeer::serving(manifest("beta", &[("local.hyperx", &["FL", "FR"])]));
    let world = World::with_peers(
        one_sink_and_firefox("A useful tab"),
        json!({ "beta": { "addresses": ["127.0.0.1"], "controlPort": peer.port, "audioPort": 46001 } }),
    );
    world.until_calls("beta's session to start", |calls| {
        calls.iter().any(|c| c.starts_with("jacktrip "))
    });
    let mut running = one_sink_and_firefox("A useful tab");
    running
        .as_array_mut()
        .unwrap()
        .extend(support::jacktrip_session(50, 500, "beta", 2, 2));
    world.stage(running.clone());
    world.until("beta to come up", |snapshot| {
        snapshot["peers"]
            .as_array()
            .is_some_and(|peers| peers.iter().any(|p| p["available"] == true))
    });

    // The peer's control endpoint goes away, and its session with it.
    peer.silence();
    world.stage(one_sink_and_firefox("A useful tab"));

    let snapshot = world.until("beta to be reported unreachable", |snapshot| {
        snapshot["peers"]
            .as_array()
            .is_some_and(|peers| peers.iter().all(|p| p["available"] == false))
    });
    assert_eq!(
        snapshot["health"]["status"], "degraded",
        "a lost peer is visible as degraded health, not as silence"
    );
    let local = snapshot["outputs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|output| output["id"] == "local.hyperx.analog-stereo")
        .expect("the local sink is still published");
    assert_eq!(
        local["available"], true,
        "the local sink is untouched by a remote failure"
    );
    assert!(
        world
            .calls_matching("pw-link -d")
            .iter()
            .all(|call| !call.contains(" 11") && !call.contains(" 12")),
        "nothing unlinked the local playback ports: {:#?}",
        world.calls_matching("pw-link -d")
    );
}

/// The behaviour the product promises, and the defect that made it impossible.
///
/// A JackTrip process outlives its peer by design: upstream's `--timeout` gives it ten seconds of
/// silence before it exits, so its ports are still sitting in the local graph when the peer is
/// already gone. Deciding whether a destination is reachable from those ports therefore reports a
/// corpse as usable, and the stream plays into it — which is exactly what the whole fleet did,
/// every endpoint `available: true` while nothing had ever carried a packet.
///
/// So this test keeps the JackTrip node staged throughout. Only the PEER goes away. The fallback
/// has to fire anyway, and the route has to come back on its own when the peer does.
#[test]
fn a_pinned_route_falls_back_and_reclaims_while_the_jacktrip_node_never_moves() {
    let peer = FakePeer::serving(manifest("beta", &[("local.hyperx", &["FL", "FR"])]));
    let world = World::with_peers(
        one_sink_and_firefox("A useful tab"),
        json!({ "beta": { "addresses": ["127.0.0.1"], "controlPort": peer.port, "audioPort": 46001 } }),
    );

    // Stage the peer's session and leave it staged for the rest of the test. Nothing below ever
    // removes it, so no assertion here can be satisfied by the node disappearing.
    let mut graph = one_sink_and_firefox("A useful tab");
    graph
        .as_array_mut()
        .unwrap()
        .extend(support::jacktrip_session(50, 500, "beta", 2, 2));
    world.stage(graph);
    world.until("beta to be usable", |snapshot| {
        snapshot["outputs"]
            .as_array()
            .is_some_and(|outputs| outputs.iter().any(|o| o["id"] == "beta.hyperx" && o["available"] == true))
    });

    world
        .ctl(&["route", "stream:200", "beta.hyperx"])
        .expect("pin the stream across the fabric");
    world.until_calls("the stream to be linked to beta's send ports", |calls| {
        calls.iter().any(|call| call == "pw-link 21 51")
    });

    // Every assertion below is against calls made AFTER the event that should have caused them.
    // Searching the whole log instead would have been satisfied by the startup routing, which links
    // this very stream to this very sink before any peer is involved -- a test that passes against
    // the bug it was written to catch.
    let before_outage = world.calls().len();

    // The peer stops answering. Its ports remain exactly where they were.
    peer.silence();
    // Wait for BOTH channels. `apply_route` links them as two separate `pw-link` invocations, so a
    // predicate satisfied by the first one races the second and fails intermittently on the
    // assertion below -- which is a test that reports a product failure it did not observe.
    world.until_calls("the sound to fall back to somewhere audible here", |calls| {
        let since = &calls[before_outage..];
        since.iter().any(|call| call == "pw-link 21 11")
            && since.iter().any(|call| call == "pw-link 22 12")
    });
    assert_eq!(
        world.persisted_state().unwrap()["routes"]["firefox|Music"],
        json!(["beta.hyperx"]),
        "the REMEMBERED route is still beta. A fallback that rewrites intent can never be undone, \
         and the peer would never get its stream back"
    );

    // ...and the same member returns, on the same address, with nobody pressing anything.
    let before_return = world.calls().len();
    peer.come_back();
    world.until_calls("the route to be reclaimed by itself", |calls| {
        let since = &calls[before_return..];
        since.iter().any(|call| call == "pw-link 21 51")
            && since.iter().any(|call| call == "pw-link 22 52")
    });
}

/// Intent has to be expressible while its destination is asleep, or it could never outlive an
/// outage — and a laptop that is shut at night is the ordinary case, not the exception.
#[test]
fn a_route_to_a_peer_that_is_not_answering_is_still_accepted_and_persisted() {
    let peer = FakePeer::serving(manifest("beta", &[("local.hyperx", &["FL", "FR"])]));
    let port = peer.port;
    peer.silence();

    let world = World::with_peers(
        one_sink_and_firefox("A useful tab"),
        json!({ "beta": { "addresses": ["127.0.0.1"], "controlPort": port, "audioPort": 46001 } }),
    );

    world
        .ctl(&["route", "stream:200", "beta.hyperx"])
        .expect("a route to a configured peer is accepted even while it is away");
    assert_eq!(
        world.persisted_state().unwrap()["routes"]["firefox|Music"],
        json!(["beta.hyperx"]),
        "and it is remembered verbatim, waiting to be honoured"
    );
    world.until_calls("the sound to go somewhere audible meanwhile", |calls| {
        calls.iter().any(|call| call == "pw-link 21 11")
    });

    let error = world
        .ctl(&["route", "stream:200", "gamma.hyperx"])
        .expect_err("but a peer that is not in the circle at all is still refused");
    assert!(error.contains("unknown output"), "{error}");
}

/// A worker that starts perfectly and then exits is the failure the supervisor cannot see from the
/// spawn, because the spawn succeeded. JackTrip does exactly this when its UDP port is already
/// bound — which is a live hazard, since the audio ports sit inside the kernel's ephemeral range.
///
/// Observed on corbet-archlxc at 04:39 today: one healthy daemon respawning both of its JackTrip
/// children every couple of seconds, indefinitely, because the backoff only covered commands that
/// could not be executed at all. The cost is a log flood and a spawn storm against a condition
/// that retrying cannot fix.
#[test]
fn a_worker_that_exits_at_once_is_backed_off_rather_than_respawned_forever() {
    let peer = FakePeer::serving(manifest("beta", &[("local.hyperx", &["FL", "FR"])]));
    let port = peer.port;
    let world = World::with_peers_running(
        one_sink_and_firefox("A useful tab"),
        json!({ "beta": { "addresses": ["127.0.0.1"], "controlPort": port, "audioPort": 46001 } }),
        "jacktrip-that-quits",
    );

    world.until_calls("the first attempt", |calls| {
        calls.iter().any(|call| call.starts_with("jacktrip "))
    });

    // Watch a window several reconcile passes wide. Unthrottled, this respawns once per 2 s pass;
    // throttled, the pauses double away from that almost immediately.
    let first = world.calls_matching("jacktrip ").len();
    std::thread::sleep(std::time::Duration::from_secs(12));
    let attempts = world.calls_matching("jacktrip ").len();
    let during_window = attempts - first;

    assert!(
        during_window <= 3,
        "a doomed worker was retried {during_window} times in 12 s; unthrottled that is ~6 and \
         never stops. Backoff is not covering a process that execs and then exits."
    );

    // ...and it must still be the peer's own problem, not the host's. The daemon answers, the local
    // graph is intact, and the peer is reported unusable rather than quietly counted as fine --
    // it answers on the control plane but has no session, so sound cannot go there.
    let snapshot = world.inspect();
    assert_ne!(
        snapshot["health"]["status"], "error",
        "one dead worker is not a dead host: {}",
        snapshot["health"]
    );
    assert!(
        snapshot["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|output| output["id"] == "local.hyperx.analog-stereo"
                && output["available"] == true),
        "the local sink is untouched by a peer that cannot carry audio"
    );
    assert_eq!(
        snapshot["peers"][0]["available"],
        json!(false),
        "a peer whose session will not stay up is not available, whatever its control plane says"
    );
}

/// A declared device that is not plugged in HERE is a naming rule that has not matched, not a
/// fault. The same declaration is deliberately made on every host the hardware can roam to, so
/// counting its absence as degradation left two of three machines permanently red over a headset
/// sitting in the third one's USB port — and a status that is always red says as little as one
/// that is always green.
#[test]
fn a_declared_device_that_is_not_plugged_in_here_is_not_a_fault() {
    let world = World::local_with_catalogue(
        one_sink_and_firefox("A useful tab"),
        // `shure` deliberately, not `hyperx`: the staged graph HAS a hyperx sink, so declaring that
        // one would prove nothing about absence.
        json!({
            "shure": { "origin": "local", "peer": null, "device": "shure",
                       "description": "Shure MV5C", "known": "declared" }
        }),
    );

    let snapshot = world.inspect();
    assert_eq!(
        snapshot["health"]["status"], "ok",
        "a roaming device that is elsewhere is not this host's fault: {}",
        snapshot["health"]
    );
    // It is still reported — as absent, which is what it is.
    assert!(
        snapshot["unavailable_devices"]
            .as_array()
            .unwrap()
            .iter()
            .any(|device| device["id"] == "local.shure"),
        "the absence is still published for a UI to show: {}",
        snapshot["unavailable_devices"]
    );
}

/// Health has to be able to go red, or it is decoration. On a host with virtual ALSA devices the
/// old "no local devices" condition is unreachable by design — snd-dummy guarantees a device — so
/// the only fault this daemon can always detect about itself is that it can no longer read the
/// graph at all. Then every field it is serving is a claim about the past, and it must say so
/// rather than keep answering confidently from a stale snapshot.
#[test]
fn a_graph_that_cannot_be_read_is_reported_as_an_error_not_served_silently() {
    let world = World::local(one_sink_and_firefox("A useful tab"));
    assert_eq!(world.inspect()["health"]["status"], "ok");

    world.break_graph_source();
    let broken = world.until("the daemon to admit it is stale", |snapshot| {
        snapshot["health"]["status"] == "error"
    });
    assert!(
        broken["health"]["message"]
            .as_str()
            .unwrap()
            .contains("stale"),
        "it says why: {}",
        broken["health"]["message"]
    );
    assert!(
        broken["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|output| output["id"] == "local.hyperx.analog-stereo"),
        "and it keeps serving the last good snapshot rather than an empty one"
    );

    world.mend_graph_source();
    world.until("the warning to retire once it can read again", |snapshot| {
        snapshot["health"]["status"] == "ok"
    });
}

/// A daemon that refuses to exist without a graph turns a transient into an outage.
///
/// `pw-dump` runs under a six second timeout. On corbet-server at load average 17 it lost that
/// race, the daemon exited, systemd restarted it straight into the same timeout, and the loop held
/// for as long as the load did — no daemon, nothing bound, both JackTrip legs gone, over a command
/// that would have succeeded a minute later.
///
/// Starting degraded is strictly better than not starting: the daemon is present, it says exactly
/// what is wrong, and it recovers by itself when the graph reads.
#[test]
fn a_daemon_that_cannot_read_the_graph_at_startup_starts_anyway_and_recovers() {
    let world = World::local_starting_blind(one_sink_and_firefox("A useful tab"));

    let blind = world.until("the daemon to answer at all", |snapshot| {
        snapshot["health"]["status"] == "error"
    });
    assert!(
        blind["health"]["message"]
            .as_str()
            .unwrap()
            .contains("initial graph read failed"),
        "it names the reason rather than dying silently: {}",
        blind["health"]["message"]
    );
    assert_eq!(
        blind["outputs"], json!([]),
        "and it claims no devices, which is true, rather than inventing any"
    );

    world.mend_graph_source();
    let recovered = world.until("it to pick the graph up by itself", |snapshot| {
        snapshot["health"]["status"] == "ok"
    });
    assert!(
        recovered["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|output| output["id"] == "local.hyperx.analog-stereo"),
        "with no restart and nobody intervening"
    );
}
