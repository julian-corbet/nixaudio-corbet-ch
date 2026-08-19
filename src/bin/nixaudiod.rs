use anyhow::{Context, Result};
use nixaudio::{
    config::Config,
    fabric,
    graph::Graph,
    state::{state_path, State},
    API_VERSION, BUS_NAME, INTERFACE, OBJECT_PATH,
};
use std::{
    path::PathBuf,
    process::Stdio,
    sync::{Arc, RwLock},
};
use tokio::{
    io::AsyncReadExt,
    sync::mpsc,
    time::{sleep, Duration},
};
use zbus::{connection::Builder, object_server::SignalEmitter};

struct Runtime {
    config: Config,
    state: State,
    state_path: PathBuf,
    fabric: fabric::Snapshot,
    graph: Graph,
    revision: u64,
}

#[derive(Clone)]
struct Controller {
    inner: Arc<RwLock<Runtime>>,
    refresh: mpsc::Sender<()>,
}

impl Controller {
    fn inspect(&self) -> Result<String> {
        Ok(serde_json::to_string_pretty(
            &self.inner.read().unwrap().graph.snapshot,
        )?)
    }
    fn route(&self, stream: &str, targets: Vec<String>) -> Result<()> {
        if targets.is_empty() {
            anyhow::bail!(
                "a route needs at least one target; use ClearRoute to return to policy routing"
            );
        }
        let mut runtime = self.inner.write().unwrap();
        // ADDRESSABLE, not available. Pinning a stream to a peer that is currently asleep has to be
        // legal: intent is a durable statement about where sound belongs, and if it could only be
        // expressed while the destination happened to be up, it could never survive an outage --
        // which is the entire behaviour this exists to provide.
        let unknown = {
            let runtime = &*runtime;
            targets
                .iter()
                .find(|target| !runtime.graph.is_addressable(&runtime.config, target))
                .cloned()
        };
        if let Some(target) = unknown {
            anyhow::bail!("unknown output {target}");
        }
        let intent = runtime.graph.stream_intent(stream)?.to_owned();
        // Record the ask before honouring it. What the user wants is the fact worth keeping;
        // whether it can be delivered this second is not, and writing the second one down is how a
        // fallback quietly becomes the intent and the route never comes back.
        runtime
            .state
            .routes
            .insert(intent, targets.iter().cloned().collect());
        runtime.state.save(&runtime.state_path)?;
        let effective = runtime.graph.resolve(&targets);
        runtime.graph.apply_route(stream, &effective)?;
        let _ = self.refresh.try_send(());
        Ok(())
    }
    fn clear_route(&self, stream: &str) -> Result<()> {
        let mut runtime = self.inner.write().unwrap();
        let intent = runtime.graph.stream_intent(stream)?.to_owned();
        runtime.state.routes.remove(&intent);
        runtime.graph.restore_default_route(stream)?;
        runtime.state.save(&runtime.state_path)?;
        let _ = self.refresh.try_send(());
        Ok(())
    }
    fn set_default(&self, endpoint: &str, output: bool) -> Result<()> {
        let mut runtime = self.inner.write().unwrap();
        let valid = if output {
            runtime
                .graph
                .snapshot
                .outputs
                .iter()
                .any(|v| v.id == endpoint && v.available)
        } else {
            runtime
                .graph
                .snapshot
                .inputs
                .iter()
                .any(|v| v.id == endpoint && v.available)
        };
        if !valid {
            anyhow::bail!(
                "{endpoint} is not an available {}",
                if output { "output" } else { "input" }
            );
        }
        runtime.graph.set_default(endpoint)?;
        if output {
            runtime.state.default_output = Some(endpoint.into())
        } else {
            runtime.state.default_input = Some(endpoint.into())
        }
        runtime.state.save(&runtime.state_path)?;
        let _ = self.refresh.try_send(());
        Ok(())
    }
    fn set_volume(&self, object: &str, volume: f64) -> Result<()> {
        self.inner
            .read()
            .unwrap()
            .graph
            .set_volume(object, volume)?;
        let _ = self.refresh.try_send(());
        Ok(())
    }
    fn set_muted(&self, object: &str, muted: bool) -> Result<()> {
        self.inner.read().unwrap().graph.set_muted(object, muted)?;
        let _ = self.refresh.try_send(());
        Ok(())
    }
}

struct AudioService {
    controller: Controller,
}

fn dbus_error(error: anyhow::Error) -> zbus::fdo::Error {
    zbus::fdo::Error::Failed(error.to_string())
}

#[zbus::interface(name = "ch.corbet.NixAudio2")]
impl AudioService {
    #[zbus(property)]
    fn api_version(&self) -> u32 {
        API_VERSION
    }
    fn inspect(&self) -> zbus::fdo::Result<String> {
        self.controller.inspect().map_err(dbus_error)
    }
    fn route(&self, stream: &str, targets: Vec<String>) -> zbus::fdo::Result<()> {
        self.controller.route(stream, targets).map_err(dbus_error)
    }
    fn clear_route(&self, stream: &str) -> zbus::fdo::Result<()> {
        self.controller.clear_route(stream).map_err(dbus_error)
    }
    fn set_default_output(&self, endpoint: &str) -> zbus::fdo::Result<()> {
        self.controller
            .set_default(endpoint, true)
            .map_err(dbus_error)
    }
    fn set_default_input(&self, endpoint: &str) -> zbus::fdo::Result<()> {
        self.controller
            .set_default(endpoint, false)
            .map_err(dbus_error)
    }
    fn set_volume(&self, object: &str, volume: f64) -> zbus::fdo::Result<()> {
        self.controller
            .set_volume(object, volume)
            .map_err(dbus_error)
    }
    fn set_muted(&self, object: &str, muted: bool) -> zbus::fdo::Result<()> {
        self.controller.set_muted(object, muted).map_err(dbus_error)
    }
    #[zbus(signal)]
    async fn changed(emitter: &SignalEmitter<'_>, revision: u64) -> zbus::Result<()>;
}

async fn watch_pipewire(events: mpsc::Sender<()>) {
    loop {
        let child = tokio::process::Command::new("pw-dump")
            .arg("--monitor")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();
        match child {
            Ok(mut child) => {
                let mut stdout = child.stdout.take().unwrap();
                let mut buffer = [0_u8; 8192];
                loop {
                    match stdout.read(&mut buffer).await {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {
                            let _ = events.try_send(());
                        }
                    }
                }
                let _ = child.kill().await;
            }
            Err(error) => eprintln!("nixaudiod: cannot monitor PipeWire: {error}"),
        }
        sleep(Duration::from_secs(2)).await;
    }
}

fn refresh(controller: &Controller, published: &Arc<RwLock<fabric::Manifest>>) -> Result<u64> {
    let mut runtime = controller.inner.write().unwrap();
    if let Ok(config) = Config::load() {
        runtime.config = config;
    }
    let next = runtime.revision + 1;
    let graph = Graph::inspect(&runtime.config, &runtime.state, &runtime.fabric, next)?;
    if let Err(error) = graph.reconcile_transport() {
        eprintln!("nixaudiod: reconcile JackTrip links: {error}");
    }
    if let Err(error) = graph.reconcile_defaults(&runtime.state) {
        eprintln!("nixaudiod: reconcile defaults: {error}");
    }
    // This one loop is BOTH the fallback and the reclaim, and that is why there is no second code
    // path for either. Every pass it asks where each stream's remembered intent can actually go
    // right now, and relinks only when that answer has changed. A peer going away changes it one
    // way; the same peer coming back changes it the other. Nobody presses anything.
    //
    // The old guard here required every remembered target to be present before touching links,
    // which meant that losing a peer was precisely the case it refused to act on: PipeWire had
    // already destroyed the links, and the stream fell silent with its route still "set".
    for stream in &graph.snapshot.streams {
        let wanted: Vec<String> = if stream.explicit_targets.is_empty() {
            graph.snapshot.default_output.clone().into_iter().collect()
        } else {
            stream.explicit_targets.clone()
        };
        if wanted.is_empty() {
            continue;
        }
        let mut effective = graph.resolve(&wanted);
        effective.sort();
        if effective.is_empty() || stream.targets == effective {
            continue;
        }
        if let Err(error) = graph.apply_route(&stream.id, &effective) {
            eprintln!("nixaudiod: reconcile {}: {error}", stream.application);
        }
    }
    *published.write().unwrap() = graph.local_manifest();
    runtime.graph = graph;
    runtime.revision = next;
    Ok(next)
}

#[tokio::main]
async fn main() -> Result<()> {
    let config = Config::load()?;
    let state_path = state_path();
    let state = State::load(&state_path)?;
    let initial_fabric = fabric::Snapshot::default();
    let graph = Graph::inspect(&config, &state, &initial_fabric, 1)
        .context("inspect initial PipeWire graph")?;
    let published = Arc::new(RwLock::new(graph.local_manifest()));
    let (events_tx, mut events_rx) = mpsc::channel(32);
    let controller = Controller {
        inner: Arc::new(RwLock::new(Runtime {
            config: config.clone(),
            state,
            state_path,
            fabric: initial_fabric,
            graph,
            revision: 1,
        })),
        refresh: events_tx.clone(),
    };
    let service = AudioService {
        controller: controller.clone(),
    };
    let connection = Builder::session()?
        .name(BUS_NAME)?
        .serve_at(OBJECT_PATH, service)?
        .build()
        .await?;
    eprintln!("nixaudiod: serving {INTERFACE} API v{API_VERSION}");

    tokio::spawn(watch_pipewire(events_tx.clone()));
    if std::env::var_os("NIXAUDIO_DISABLE_NETWORK").is_none() {
        let server_config = config.clone();
        let server_manifest = published.clone();
        tokio::spawn(async move {
            loop {
                if let Err(error) =
                    fabric::serve(server_config.clone(), server_manifest.clone()).await
                {
                    eprintln!("nixaudiod: control server: {error:#}");
                }
                sleep(Duration::from_secs(2)).await;
            }
        });

        let fabric_controller = controller.clone();
        let fabric_events = events_tx.clone();
        let local_manifest = published.clone();
        tokio::spawn(async move {
            let mut transport = fabric::Runtime::default();
            loop {
                let config = match Config::load() {
                    Ok(config) => {
                        fabric_controller.inner.write().unwrap().config = config.clone();
                        config
                    }
                    Err(error) => {
                        eprintln!("nixaudiod: keep last configuration: {error}");
                        fabric_controller.inner.read().unwrap().config.clone()
                    }
                };
                let manifest = local_manifest.read().unwrap().clone();
                match transport.reconcile(&config, &manifest).await {
                    Ok(snapshot) => fabric_controller.inner.write().unwrap().fabric = snapshot,
                    Err(error) => eprintln!("nixaudiod: fabric reconciliation: {error:#}"),
                }
                let _ = fabric_events.try_send(());
                sleep(Duration::from_secs(2)).await;
            }
        });
    }

    while events_rx.recv().await.is_some() {
        sleep(Duration::from_millis(120)).await;
        while events_rx.try_recv().is_ok() {}
        let worker = controller.clone();
        let worker_manifest = published.clone();
        match tokio::task::spawn_blocking(move || refresh(&worker, &worker_manifest)).await {
            Ok(Ok(revision)) => {
                let emitter = SignalEmitter::new(&connection, OBJECT_PATH)?;
                AudioService::changed(&emitter, revision).await?;
            }
            Ok(Err(error)) => eprintln!("nixaudiod: graph refresh: {error}"),
            Err(error) => eprintln!("nixaudiod: graph worker: {error}"),
        }
    }
    Ok(())
}
