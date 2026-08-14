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
