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
        for target in &targets {
            if !runtime.graph.has_endpoint(target) {
                anyhow::bail!("unknown or unavailable output {target}");
            }
        }
        runtime.graph.apply_route(stream, &targets)?;
        let intent = runtime.graph.stream_intent(stream)?.to_owned();
        runtime
            .state
            .routes
            .insert(intent, targets.into_iter().collect());
        runtime.state.save(&runtime.state_path)?;
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
                .any(|v| v.id == endpoint)
        } else {
            runtime
                .graph
                .snapshot
                .inputs
                .iter()
                .any(|v| v.id == endpoint)
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

#[zbus::interface(name = "ch.corbet.NixAudio1")]
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

fn refresh(controller: &Controller) -> Result<u64> {
    let mut runtime = controller.inner.write().unwrap();
    if let Ok(config) = Config::load() {
        runtime.config = config;
    }
    let next = runtime.revision + 1;
    let graph = Graph::inspect(&runtime.config, &runtime.state, next)?;
    if let Err(error) = graph.reconcile_defaults(&runtime.state) {
        eprintln!("nixaudiod: reconcile defaults: {error}");
    }
    for stream in &graph.snapshot.streams {
        if !stream.explicit_targets.is_empty()
            && stream.targets != stream.explicit_targets
            && stream
                .explicit_targets
                .iter()
                .all(|v| graph.has_endpoint(v))
        {
            if let Err(error) = graph.apply_route(&stream.id, &stream.explicit_targets) {
                eprintln!("nixaudiod: reconcile {}: {error}", stream.application);
            }
        }
    }
    runtime.graph = graph;
    runtime.revision = next;
    Ok(next)
}

#[tokio::main]
async fn main() -> Result<()> {
    let config = Config::load()?;
    let state_path = state_path();
    let state = State::load(&state_path)?;
    let graph = Graph::inspect(&config, &state, 1).context("inspect initial PipeWire graph")?;
    let (events_tx, mut events_rx) = mpsc::channel(32);
    let controller = Controller {
        inner: Arc::new(RwLock::new(Runtime {
            config,
            state,
            state_path,
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
    if std::env::var_os("NIXAUDIO_DISABLE_FABRIC").is_none() {
        let fabric_controller = controller.clone();
        let fabric_events = events_tx.clone();
        tokio::spawn(async move {
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
                match tokio::task::spawn_blocking(move || fabric::reconcile(&config)).await {
                    Ok(Err(error)) => eprintln!("nixaudiod: fabric reconciliation: {error}"),
                    Err(error) => eprintln!("nixaudiod: fabric worker: {error}"),
                    _ => {}
                }
                let _ = fabric_events.try_send(());
                sleep(Duration::from_secs(15)).await;
            }
        });
    }

    while events_rx.recv().await.is_some() {
        sleep(Duration::from_millis(120)).await;
        while events_rx.try_recv().is_ok() {}
        let worker = controller.clone();
        match tokio::task::spawn_blocking(move || refresh(&worker)).await {
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
