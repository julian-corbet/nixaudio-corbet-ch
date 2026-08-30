//! A whole `nixaudiod`, running against a world made of shell scripts.
//!
//! The daemon reaches the outside world through four commands and three environment variables,
//! and every one of them is interceptable without changing a line of production code:
//!
//! * `pw-dump`, `pw-link` and `wpctl` are resolved through `PATH` (`graph.rs` shells out via
//!   `timeout`, which execs), so a fixture directory placed first replaces all three.
//! * `jacktrip` comes from `transport.command` in the config, so it is replaced by writing a field.
//! * `NIXAUDIO_CONFIG`, `XDG_STATE_HOME` and `DBUS_SESSION_BUS_ADDRESS` place the config, the
//!   persisted state and the bus inside a temporary directory.
//!
//! Each `World` gets a private session bus. The daemon claims a well-known name, so tests sharing
//! one bus would race for it and fail in whichever order the scheduler chose.

#![allow(dead_code)]

use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader},
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

/// How long a test waits for the daemon to reach a state before calling it a failure.
///
/// The refresh path debounces 120 ms, which this used to be generous against by two orders of
/// magnitude. It no longer is, and the reason matters: declaring a peer unreachable deliberately
/// costs three consecutive failed probes on a two-second reconcile, so roughly six seconds pass
/// before anything observable happens -- by design, so a Wi-Fi roam is not an outage. Ten seconds
/// left an outage test finishing at 8.2 s, which is a flake waiting to happen. A flaky timeout is
/// worse than a slow failure.
const PATIENCE: Duration = Duration::from_secs(30);

/// How long any single `nixaudioctl` call may take before the harness gives up on it. Well under
/// `PATIENCE`, so a stuck call surfaces as a failed call rather than as a stalled poll loop.
const CALL_PATIENCE: Duration = Duration::from_secs(5);

pub struct World {
    control_port: u16,
    directory: tempfile::TempDir,
    bus: Child,
    bus_address: String,
    daemon: Option<Child>,
    graph_path: PathBuf,
    stderr_path: PathBuf,
    events_path: PathBuf,
    log_path: PathBuf,
    config_path: PathBuf,
    state_home: PathBuf,
}

impl World {
    /// Stage a graph, declare a device catalogue, and start a daemon with the fabric off. The
    /// catalogue is what a host says it expects to have names for; a test needs one to say anything
    /// about a device that is declared and not present.
    pub fn local_with_catalogue(graph: Value, catalogue: Value) -> Self {
        Self::new(graph, |config| {
            config["peers"] = json!({});
            config["catalogue"] = catalogue;
        })
        .started(true)
    }

    /// Stage a graph and start a daemon with NO peers but the control server LISTENING, so a test
    /// can fetch the manifest this host publishes exactly as a peer would. Peerless on purpose:
    /// what a host advertises is a property of the host, not of who is asking.
    pub fn local_but_reachable(graph: Value) -> Self {
        Self::new(graph, |config| {
            config["peers"] = json!({});
        })
        .started(false)
    }

    /// Stage a graph and start a daemon against it, with the fabric switched off. Most tests are
    /// about the local graph and want no peer traffic at all.
    pub fn local(graph: Value) -> Self {
        Self::new(graph, |config| {
            config["peers"] = json!({});
        })
        .started(true)
    }

    /// Stage a graph and start a daemon with the fabric live, talking to `peers`.
    pub fn with_peers(graph: Value, peers: Value) -> Self {
        Self::new(graph, |config| {
            config["peers"] = peers;
        })
        .started(false)
    }

    /// Stage a graph and start a daemon with the fabric live, talking to `peers`, but launching
    /// something other than the healthy JackTrip stand-in. The command is the one interception
    /// point that needs no production change, so a test can supply a worker that fails in a
    /// specific way -- exits at once, refuses to bind -- and watch how the supervisor answers.
    pub fn with_peers_running(graph: Value, peers: Value, jacktrip_fixture: &str) -> Self {
        let command = fixtures_directory().join(jacktrip_fixture);
        assert!(
            command.is_file(),
            "no such jacktrip fixture: {}",
            command.display()
        );
        Self::new(graph, |config| {
            config["peers"] = peers;
            config["transport"]["command"] = json!([command.to_str().unwrap()]);
        })
        .started(false)
    }

    /// Start a daemon whose PipeWire refuses to answer from the very first read, as a host under
    /// enough load that `pw-dump` loses its timeout before anything has ever succeeded.
    pub fn local_starting_blind(graph: Value) -> Self {
        let world = Self::new(graph, |config| {
            config["peers"] = json!({});
        });
        std::fs::write(world.graph_path.with_extension("json.broken"), b"").unwrap();
        world.started(true)
    }

    fn new(graph: Value, customise: impl FnOnce(&mut Value)) -> Self {
        let directory = tempfile::tempdir().expect("temporary directory");
        let root = directory.path().to_path_buf();
        let fixtures = fixtures_directory();

        let graph_path = root.join("graph.json");
        let stderr_path = root.join("daemon.stderr");
        let events_path = root.join("events");
        let log_path = root.join("calls.log");
        let config_path = root.join("config.json");
        let state_home = root.join("state");

        std::fs::write(&graph_path, serde_json::to_vec(&graph).unwrap()).unwrap();
        std::fs::write(&events_path, b"").unwrap();
        std::fs::write(&log_path, b"").unwrap();

        let control_port = free_port();
        let mut config = json!({
            "node": "alpha",
            "control": { "listen": "127.0.0.1", "port": control_port },
            "transport": { "command": [fixtures.join("jacktrip").to_str().unwrap()] },
            "peers": {},
            "catalogue": {},
        });
        customise(&mut config);
        std::fs::write(&config_path, serde_json::to_vec_pretty(&config).unwrap()).unwrap();

        let (bus, bus_address) = start_bus(&root);

        Self {
            control_port,
            directory,
            bus,
            bus_address,
            daemon: None,
            graph_path,
            stderr_path,
            events_path,
            log_path,
            config_path,
            state_home,
        }
    }

    fn started(mut self, offline: bool) -> Self {
        self.start_daemon(offline);
        self
    }

    fn start_daemon(&mut self, offline: bool) {
        let mut command = Command::new(env!("CARGO_BIN_EXE_nixaudiod"));
        self.apply_environment(&mut command, offline);
        // Appended to a file rather than piped. A pipe nobody drains is a promise this harness
        // cannot keep: every panic here offers the daemon's stderr, and a restart-based test
        // needs the output from BEFORE the restart to still be there afterwards.
        let log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.stderr_path)
            .expect("daemon stderr log");
        let child = command
            .stdout(Stdio::null())
            .stderr(Stdio::from(log))
            .spawn()
            .expect("start nixaudiod");
        self.daemon = Some(child);
        self.await_bus_name();
    }

    fn apply_environment(&self, command: &mut Command, offline: bool) {
        let fixtures = fixtures_directory();
        let path = match std::env::var_os("PATH") {
            Some(existing) => format!("{}:{}", fixtures.display(), existing.to_string_lossy()),
            None => fixtures.display().to_string(),
        };
        command
            .env("PATH", path)
            .env("DBUS_SESSION_BUS_ADDRESS", &self.bus_address)
            .env("NIXAUDIO_CONFIG", &self.config_path)
            .env("XDG_STATE_HOME", &self.state_home)
            .env("NIXAUDIO_FAKE_GRAPH", &self.graph_path)
            .env("NIXAUDIO_FAKE_EVENTS", &self.events_path)
            .env("NIXAUDIO_FAKE_LOG", &self.log_path);
        if offline {
            command.env("NIXAUDIO_DISABLE_NETWORK", "1");
        } else {
            command.env_remove("NIXAUDIO_DISABLE_NETWORK");
        }
    }

    /// Restart the daemon against the same state directory, which is how persistence is proved:
    /// anything the daemon remembers has to survive its own process.
    pub fn restart(&mut self) {
        self.stop_daemon();
        self.start_daemon(true);
    }

    /// Remove the private session bus and wait for the daemon to notice. A production user
    /// service is restarted by systemd; the harness observes the process boundary directly so a
    /// daemon that keeps serving audio but has silently lost its API cannot pass.
    pub fn disconnect_bus_and_wait_for_daemon(&mut self) -> ExitStatus {
        let _ = self.bus.kill();
        let _ = self.bus.wait();

        let deadline = Instant::now() + PATIENCE;
        let daemon = self.daemon.as_mut().expect("a running daemon");
        loop {
            match daemon.try_wait().expect("poll nixaudiod after bus loss") {
                Some(status) => return status,
                None if Instant::now() >= deadline => {
                    panic!(
                        "nixaudiod stayed alive after its session bus disappeared\ndaemon stderr: {}",
                        std::fs::read_to_string(&self.stderr_path).unwrap_or_default(),
                    )
                }
                None => sleep(Duration::from_millis(20)),
            }
        }
    }

    fn stop_daemon(&mut self) {
        if let Some(mut daemon) = self.daemon.take() {
            let _ = daemon.kill();
            let _ = daemon.wait();
        }
    }

    /// Print raw text into the monitor stream, exactly as `pw-dump --monitor` prints a batch.
    ///
    /// `notify` sends a bare nudge, which the daemon takes at face value. This one lets a test
    /// hand it a REAL batch and find out whether it decides to care.
    pub fn inject(&self, batch: &str) {
        use std::io::Write;
        let mut events = std::fs::OpenOptions::new()
            .append(true)
            .open(&self.events_path)
            .unwrap();
        writeln!(events, "{batch}").unwrap();
    }

    /// Poison the graph read WITHOUT nudging the daemon.
    ///
    /// The poison is invisible until something makes it run `pw-dump` again, which turns "did
    /// this event wake the daemon?" into a question a test can actually ask: `health` going red
    /// is proof it looked, and staying green is proof it did not.
    pub fn break_graph_source_quietly(&self) {
        std::fs::write(self.graph_path.with_extension("json.broken"), b"").unwrap();
    }

    /// Make the graph read fail, as a PipeWire that has stopped answering.
    pub fn break_graph_source(&self) {
        std::fs::write(self.graph_path.with_extension("json.broken"), b"").unwrap();
        self.notify();
    }

    /// Let it answer again.
    pub fn mend_graph_source(&self) {
        let _ = std::fs::remove_file(self.graph_path.with_extension("json.broken"));
        self.notify();
    }

    /// The manifest a PEER receives, fetched the way a peer fetches it: over the control port,
    /// with the real greeting. Asserting on this rather than on the local snapshot is the
    /// difference between checking a flag and checking the behaviour the flag is supposed to cause.
    pub fn published_manifest(&self) -> Value {
        use std::io::{Read, Write};
        let deadline = Instant::now() + PATIENCE;
        loop {
            match std::net::TcpStream::connect(("127.0.0.1", self.control_port)) {
                Ok(mut stream) => {
                    stream.write_all(b"NXAUDIO/1 MANIFEST\n").unwrap();
                    stream.shutdown(std::net::Shutdown::Write).ok();
                    let mut body = String::new();
                    stream.read_to_string(&mut body).unwrap();
                    return serde_json::from_str(&body).expect("a peer receives JSON");
                }
                Err(error) if Instant::now() < deadline => {
                    let _ = error;
                    sleep(Duration::from_millis(50));
                }
                Err(error) => panic!("the control port never answered: {error}"),
            }
        }
    }

    pub fn stage(&self, graph: Value) {
        std::fs::write(&self.graph_path, serde_json::to_vec(&graph).unwrap()).unwrap();
        self.notify();
    }

    /// Emit one PipeWire change event.
    pub fn notify(&self) {
        use std::io::Write;
        let mut events = std::fs::OpenOptions::new()
            .append(true)
            .open(&self.events_path)
            .unwrap();
        events.write_all(b"changed\n").unwrap();
    }

    /// Run `nixaudioctl` against this world's daemon and return its stdout.
    ///
    /// Bounded, and that matters more than it looks: a D-Bus call with no reply blocks forever, so
    /// an unbounded call here would sit inside the polling loops below and stop their deadlines
    /// from ever being evaluated. The suite would hang instead of failing, which is how a broken
    /// bus policy once cost more time than the bug it was hiding.
    pub fn ctl(&self, arguments: &[&str]) -> Result<String, String> {
        let mut command = Command::new(env!("CARGO_BIN_EXE_nixaudioctl"));
        self.apply_environment(&mut command, true);
        let mut child = command
            .args(arguments)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("run nixaudioctl");

        let deadline = Instant::now() + CALL_PATIENCE;
        loop {
            match child.try_wait().expect("poll nixaudioctl") {
                Some(_) => break,
                None if Instant::now() >= deadline => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!(
                        "nixaudioctl {} never returned within {CALL_PATIENCE:?}",
                        arguments.join(" ")
                    ));
                }
                None => sleep(Duration::from_millis(20)),
            }
        }

        let output = child
            .wait_with_output()
            .expect("collect nixaudioctl output");
        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).into_owned())
        } else {
            Err(String::from_utf8_lossy(&output.stderr).into_owned())
        }
    }

    /// The daemon's own view of the world, as the tray and the CLI see it.
    pub fn inspect(&self) -> Value {
        let raw = self.ctl(&["inspect"]).expect("inspect");
        serde_json::from_str(&raw).expect("inspect returns JSON")
    }

    /// Every external command the daemon has run, in order.
    pub fn calls(&self) -> Vec<String> {
        std::fs::read_to_string(&self.log_path)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    pub fn calls_matching(&self, prefix: &str) -> Vec<String> {
        self.calls()
            .into_iter()
            .filter(|line| line.starts_with(prefix))
            .collect()
    }

    /// The persisted state file, or `None` if the daemon has not written one.
    pub fn persisted_state(&self) -> Option<Value> {
        let path = self.state_home.join("nixaudio/state.json");
        std::fs::read(path)
            .ok()
            .map(|bytes| serde_json::from_slice(&bytes).expect("state.json is JSON"))
    }

    /// Poll until `predicate` accepts a snapshot, or fail with the last one seen.
    pub fn until(&self, what: &str, predicate: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + PATIENCE;
        let mut last = Value::Null;
        while Instant::now() < deadline {
            last = self.inspect();
            if predicate(&last) {
                return last;
            }
            sleep(Duration::from_millis(50));
        }
        panic!(
            "timed out waiting for {what}\nlast snapshot: {}\ncalls: {:#?}\ndaemon stderr: {}",
            serde_json::to_string_pretty(&last).unwrap_or_default(),
            self.calls(),
            self.daemon_stderr(),
        );
    }

    /// Poll until the recorded calls satisfy `predicate`.
    pub fn until_calls(&self, what: &str, predicate: impl Fn(&[String]) -> bool) -> Vec<String> {
        let deadline = Instant::now() + PATIENCE;
        while Instant::now() < deadline {
            let calls = self.calls();
            if predicate(&calls) {
                return calls;
            }
            sleep(Duration::from_millis(50));
        }
        panic!(
            "timed out waiting for {what}\ncalls so far: {:#?}\ndaemon stderr: {}",
            self.calls(),
            self.daemon_stderr(),
        );
    }

    pub fn daemon_stderr(&self) -> String {
        std::fs::read_to_string(&self.stderr_path).unwrap_or_default()
    }

    fn await_bus_name(&self) {
        let deadline = Instant::now() + PATIENCE;
        while Instant::now() < deadline {
            if self.ctl(&["inspect"]).is_ok() {
                return;
            }
            sleep(Duration::from_millis(50));
        }
        panic!("nixaudiod never claimed ch.corbet.NixAudio2 on the private bus");
    }
}

impl Drop for World {
    fn drop(&mut self) {
        self.stop_daemon();
        let _ = self.bus.kill();
        let _ = self.bus.wait();
    }
}

fn fixtures_directory() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/bin")
}

/// A port the control endpoint can bind. Binding and dropping leaves it free; the window between
/// that and the daemon claiming it is not worth a more elaborate scheme for a test.
fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("reserve a port")
        .local_addr()
        .expect("port")
        .port()
}

/// A session bus that belongs to one test and depends on nothing outside its own directory.
///
/// `dbus-daemon --session` reads a configuration file from a compiled-in system path, which does
/// not exist in the Nix build sandbox -- it starts, prints no address and exits, which is what
/// made the whole suite fail there while passing on a developer's machine. Writing the config
/// ourselves removes the host from the picture entirely.
fn start_bus(root: &Path) -> (Child, String) {
    let config = root.join("session.conf");
    // The listen address is /tmp rather than this test's own directory on purpose: a Unix socket
    // path is capped at 108 bytes by sun_path, and TMPDIR under a build sandbox or a scratch tree
    // is easily long enough to exceed it, at which point dbus-daemon exits with "Socket name too
    // long" and prints no address at all. /tmp is short everywhere this runs and the daemon
    // unlinks the socket when it exits.
    //
    // All three policy rules matter. Allowing sends without allowing receives lets a method call
    // through and then discards its reply, so the caller blocks forever waiting for an answer
    // policy already threw away. That is a hang rather than an error, which is the worst way for
    // a test harness to fail. This mirrors the stock session.conf.
    //
    // Note for anyone editing the XML below: a comment inside it may not contain two consecutive
    // hyphens, which is why this explanation lives out here in Rust.
    std::fs::write(
        &config,
        r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#,
    )
    .expect("write a private session bus configuration");

    let errors = root.join("dbus.err");
    let mut bus = Command::new("dbus-daemon")
        .arg(format!("--config-file={}", config.display()))
        .args(["--nofork", "--nopidfile", "--print-address"])
        .stdout(Stdio::piped())
        .stderr(Stdio::from(
            std::fs::File::create(&errors).expect("capture bus diagnostics"),
        ))
        .spawn()
        .expect("start a private session bus (is dbus-daemon on PATH?)");
    let stdout = bus.stdout.take().expect("bus address");
    let mut address = String::new();
    BufReader::new(stdout)
        .read_line(&mut address)
        .expect("read bus address");
    let address = address.trim().to_owned();
    assert!(
        !address.is_empty(),
        "dbus-daemon printed no address: {}",
        std::fs::read_to_string(&errors).unwrap_or_default().trim()
    );
    (bus, address)
}

/// Another circle member, reduced to the only thing nixaudio asks of one: answer the greeting
/// with a manifest. Real enough to exercise `fetch` -> `plan` -> `spawn_worker` end to end,
/// without a network, a second daemon, or a JackTrip.
pub struct FakePeer {
    pub port: u16,
    manifest: Value,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl FakePeer {
    pub fn serving(manifest: Value) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind a fake peer");
        let port = listener.local_addr().unwrap().port();
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        Self::answer(listener, manifest.clone(), stop.clone());
        Self {
            port,
            manifest,
            stop,
        }
    }

    fn answer(
        listener: TcpListener,
        manifest: Value,
        flag: std::sync::Arc<std::sync::atomic::AtomicBool>,
    ) {
        listener
            .set_nonblocking(true)
            .expect("poll rather than block forever on accept");
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            const GREETING: usize = "NXAUDIO/1 MANIFEST\n".len();
            let body = serde_json::to_vec(&manifest).unwrap();
            while !flag.load(std::sync::atomic::Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let mut greeting = vec![0_u8; GREETING];
                        stream.set_nonblocking(false).ok();
                        if stream.read_exact(&mut greeting).is_err() {
                            continue;
                        }
                        let _ = stream.write_all(&body);
                        let _ = stream.shutdown(std::net::Shutdown::Write);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        sleep(Duration::from_millis(10))
                    }
                    Err(_) => break,
                }
            }
            drop(listener);
        });
    }

    /// Stop answering, as a peer whose control endpoint has gone away. Returns once the port is
    /// actually refusing connections, so a test cannot race the outage it just caused.
    pub fn silence(&self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        let address = format!("127.0.0.1:{}", self.port).parse().unwrap();
        for _ in 0..400 {
            if std::net::TcpStream::connect_timeout(&address, Duration::from_millis(50)).is_err() {
                return;
            }
            sleep(Duration::from_millis(10));
        }
        panic!("fake peer on {} never stopped answering", self.port);
    }

    /// Answer again on the SAME port, as the same member coming back. Identity is the port here,
    /// exactly as it is an address in the real thing: nothing about the peer changed while it was
    /// away, which is the whole point of the behaviour being tested.
    pub fn come_back(&self) {
        self.stop
            .store(false, std::sync::atomic::Ordering::Relaxed);
        // Retry rather than expect. The port was ephemeral, so while this peer was away the kernel
        // was free to hand it to any other test binding :0 -- and the suite runs them in parallel,
        // which turned a real race into an intermittent panic that looked like a product failure.
        let deadline = Instant::now() + PATIENCE;
        loop {
            match TcpListener::bind(("127.0.0.1", self.port)) {
                Ok(listener) => {
                    Self::answer(listener, self.manifest.clone(), self.stop.clone());
                    return;
                }
                Err(error) if Instant::now() < deadline => {
                    let _ = error;
                    sleep(Duration::from_millis(20));
                }
                Err(error) => panic!("fake peer could not reclaim port {}: {error}", self.port),
            }
        }
    }
}

impl Drop for FakePeer {
    fn drop(&mut self) {
        self.silence();
    }
}

/// A manifest as a peer publishes it: semantic endpoint ids and channel names, never PipeWire
/// object ids.
pub fn manifest(node: &str, outputs: &[(&str, &[&str])]) -> Value {
    json!({
        "protocol": 1,
        "node": node,
        "revision": 1,
        "outputs": outputs.iter().map(|(id, channels)| json!({
            "id": id,
            "label": id,
            "channels": channels,
        })).collect::<Vec<_>>(),
        "inputs": [],
    })
}

/// The PipeWire node a JackTrip session registers once it is actually running, with the send and
/// receive port slices its plan allocated.
///
/// nixaudio treats a peer as reachable only when this node exists: a process that was spawned but
/// has not registered its ports carries no audio, and reporting it as available would make the
/// health signal a statement about our own intentions rather than about the circle.
pub fn jacktrip_session(id: u32, serial: u64, peer: &str, send: u32, receive: u32) -> Vec<Value> {
    let name = format!("nixaudio-jt-{peer}");
    let mut values = vec![
        json!({"id": id, "type": "PipeWire:Interface:Node", "info": {"props": {
            "object.serial": serial,
            "node.name": name,
            "node.description": name,
        }}}),
    ];
    for index in 1..=send {
        values.push(port(id + index, id, &format!("send_{index}"), "in", ""));
    }
    for index in 1..=receive {
        values.push(port(
            id + 100 + index,
            id,
            &format!("receive_{index}"),
            "out",
            "",
        ));
    }
    values
}

/// A PipeWire sink node, as `pw-dump` renders one.
pub fn sink(id: u32, serial: u64, node_name: &str, device: &str, profile: &str) -> Value {
    json!({"id": id, "type": "PipeWire:Interface:Node", "info": {"props": {
        "object.serial": serial,
        "node.name": node_name,
        "node.description": device,
        "media.class": "Audio/Sink",
        "alsa.nixaudio.device": device,
        "device.profile.name": profile,
    }}})
}

/// An application playing audio.
pub fn stream(id: u32, serial: u64, application: &str, title: &str, role: &str) -> Value {
    json!({"id": id, "type": "PipeWire:Interface:Node", "info": {"props": {
        "object.serial": serial,
        "node.name": application,
        "media.name": title,
        "media.class": "Stream/Output/Audio",
        "application.name": application,
        "application.process.binary": application.to_lowercase(),
        "media.role": role,
    }}})
}

pub fn port(id: u32, node: u32, name: &str, direction: &str, channel: &str) -> Value {
    json!({"id": id, "type": "PipeWire:Interface:Port", "info": {"props": {
        "node.id": node,
        "port.name": name,
        "port.direction": direction,
        "audio.channel": channel,
    }}})
}

pub fn link(
    id: u32,
    output_node: u32,
    output_port: u32,
    input_node: u32,
    input_port: u32,
) -> Value {
    json!({"id": id, "type": "PipeWire:Interface:Link", "info": {
        "output-node-id": output_node,
        "output-port-id": output_port,
        "input-node-id": input_node,
        "input-port-id": input_port,
    }})
}
