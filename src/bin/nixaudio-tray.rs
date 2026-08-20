use anyhow::{Context, Result};
use futures_util::StreamExt;
use ksni::{
    menu::{CheckmarkItem, StandardItem, SubMenu},
    Category, MenuItem, Status, ToolTip, Tray, TrayMethods,
};
use nixaudio::{
    api::AudioProxy,
    graph::{Endpoint, Snapshot, Stream},
    API_VERSION,
};
use std::{collections::BTreeSet, sync::Arc};
use tokio::{
    sync::mpsc,
    time::{sleep, Duration},
};

#[derive(Debug)]
enum Action {
    Route {
        stream: String,
        target: String,
        enabled: bool,
    },
    ClearRoute(String),
    DefaultOutput(String),
    DefaultInput(String),
    Volume {
        object: String,
        value: f64,
    },
    Muted {
        object: String,
        value: bool,
    },
}

#[derive(Debug)]
struct AudioTray {
    snapshot: Option<Snapshot>,
    error: Option<String>,
    actions: mpsc::UnboundedSender<Action>,
}

impl AudioTray {
    fn default_output(&self) -> Option<&Endpoint> {
        let snapshot = self.snapshot.as_ref()?;
        snapshot
            .default_output
            .as_ref()
            .and_then(|id| snapshot.outputs.iter().find(|v| &v.id == id))
    }

    fn volume_actions(object: &str, volume: f64, muted: bool) -> Vec<MenuItem<Self>> {
        let lower_id = object.to_owned();
        let lower = (volume - 0.05).max(0.0);
        let raise_id = object.to_owned();
        let raise = (volume + 0.05).min(1.5);
        let mute_id = object.to_owned();
        vec![
            StandardItem {
                label: "Volume -5%".into(),
                activate: Box::new(move |this: &mut Self| {
                    let _ = this.actions.send(Action::Volume {
                        object: lower_id.clone(),
                        value: lower,
                    });
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Volume +5%".into(),
                activate: Box::new(move |this: &mut Self| {
                    let _ = this.actions.send(Action::Volume {
                        object: raise_id.clone(),
                        value: raise,
                    });
                }),
                ..Default::default()
            }
            .into(),
            CheckmarkItem {
                label: "Muted".into(),
                checked: muted,
                activate: Box::new(move |this: &mut Self| {
                    let _ = this.actions.send(Action::Muted {
                        object: mute_id.clone(),
                        value: !muted,
                    });
                }),
                ..Default::default()
            }
            .into(),
        ]
    }

    fn output_menu(&self, snapshot: &Snapshot) -> MenuItem<Self> {
        let items = snapshot
            .outputs
            .iter()
            .map(|endpoint| {
                let id = endpoint.id.clone();
                CheckmarkItem {
                    label: format!("{}  —  {}", endpoint.id, endpoint.label),
                    checked: snapshot.default_output.as_deref() == Some(endpoint.id.as_str()),
                    enabled: endpoint.available,
                    activate: Box::new(move |this: &mut Self| {
                        let _ = this.actions.send(Action::DefaultOutput(id.clone()));
                    }),
                    ..Default::default()
                }
                .into()
            })
            .collect();
        SubMenu {
            label: "Default output".into(),
            icon_name: "audio-speakers".into(),
            submenu: items,
            ..Default::default()
        }
        .into()
    }

    fn input_menu(&self, snapshot: &Snapshot) -> MenuItem<Self> {
        let items = snapshot
            .inputs
            .iter()
            .map(|endpoint| {
                let id = endpoint.id.clone();
                CheckmarkItem {
                    label: format!("{}  —  {}", endpoint.id, endpoint.label),
                    checked: snapshot.default_input.as_deref() == Some(endpoint.id.as_str()),
                    enabled: endpoint.available,
                    activate: Box::new(move |this: &mut Self| {
                        let _ = this.actions.send(Action::DefaultInput(id.clone()));
                    }),
                    ..Default::default()
                }
                .into()
            })
            .collect();
        SubMenu {
            label: "Default microphone".into(),
            icon_name: "audio-input-microphone".into(),
            submenu: items,
            ..Default::default()
        }
        .into()
    }

    fn stream_menu(stream: &Stream, outputs: &[Endpoint]) -> MenuItem<Self> {
        // Ticks show INTENT, never the links that happen to exist. `targets` is where the sound is
        // going right now, which for a stream following the default is the default, and for a
        // stream whose destination is away is the fallback. Ticking from that meant a click either
        // pinned the default the user had never chosen, or -- once routes started falling back --
        // silently rewrote the pin to wherever the outage had pushed it.
        let selected: BTreeSet<&str> = stream.explicit_targets.iter().map(String::as_str).collect();
        let mut items: Vec<MenuItem<Self>> = outputs
            .iter()
            .map(|endpoint| {
                let stream_id = stream.id.clone();
                let target = endpoint.id.clone();
                let enabled = selected.contains(target.as_str());
                CheckmarkItem {
                    label: format!("{}  —  {}", endpoint.id, endpoint.label),
                    checked: enabled,
                    activate: Box::new(move |this: &mut Self| {
                        let _ = this.actions.send(Action::Route {
                            stream: stream_id.clone(),
                            target: target.clone(),
                            enabled: !enabled,
                        });
                    }),
                    ..Default::default()
                }
                .into()
            })
            .collect();
        items.push(MenuItem::Separator);
        items.extend(Self::volume_actions(
            &stream.id,
            stream.volume,
            stream.muted,
        ));
        let clear = stream.id.clone();
        items.push(MenuItem::Separator);
        items.push(
            StandardItem {
                label: "Follow default output".into(),
                activate: Box::new(move |this: &mut Self| {
                    let _ = this.actions.send(Action::ClearRoute(clear.clone()));
                }),
                ..Default::default()
            }
            .into(),
        );
        // When effect and intent disagree -- a pinned peer is away and the sound is falling back
        // here -- say so on the label. The alternative is a ticked box and sound coming out
        // somewhere else, with nothing on screen admitting it.
        let mut label = format!(
            "{} · {}% · {}",
            stream.application,
            (stream.volume * 100.0).round(),
            stream.title
        );
        if !stream.explicit_targets.is_empty() && stream.targets != stream.explicit_targets {
            if let Some(actual) = stream.targets.first() {
                label.push_str(&format!("  (on {actual})"));
            }
        }
        SubMenu {
            label,
            submenu: items,
            ..Default::default()
        }
        .into()
    }
}

impl Tray for AudioTray {
    const MENU_ON_ACTIVATE: bool = true;
    fn id(&self) -> String {
        "nixaudio".into()
    }
    fn title(&self) -> String {
        "nixaudio".into()
    }
    fn category(&self) -> Category {
        Category::Hardware
    }
    fn status(&self) -> Status {
        match self.snapshot.as_ref().map(|v| v.health.status.as_str()) {
            Some("ok") => Status::Active,
            _ => Status::NeedsAttention,
        }
    }
    fn icon_name(&self) -> String {
        let Some(output) = self.default_output() else {
            return "audio-volume-muted".into();
        };
        // An icon that shows a level is a claim to know one. A remote endpoint publishes none, so
        // it gets the plain speaker rather than a bar height picked out of the air.
        let (Some(volume), Some(muted)) = (output.volume, output.muted) else {
            return "audio-speakers".into();
        };
        if muted || volume == 0.0 {
            "audio-volume-muted"
        } else if volume < 0.34 {
            "audio-volume-low"
        } else if volume < 0.67 {
            "audio-volume-medium"
        } else {
            "audio-volume-high"
        }
        .into()
    }
    fn overlay_icon_name(&self) -> String {
        if self
            .snapshot
            .as_ref()
            .is_some_and(|v| v.inputs.iter().any(|input| input.muted == Some(true)))
        {
            "microphone-sensitivity-muted".into()
        } else {
            String::new()
        }
    }
    fn tool_tip(&self) -> ToolTip {
        if let Some(snapshot) = &self.snapshot {
            let output = self
                .default_output()
                .map(|v| match v.volume {
                    Some(level) => format!("{} ({}%)", v.id, (level * 100.0).round()),
                    // The one place this actually leaked: a peer's speakers were shown at "100%",
                    // which is not a reading, it is the absence of one.
                    None => format!("{} (level not published)", v.id),
                })
                .unwrap_or_else(|| "no default output".into());
            ToolTip {
                icon_name: self.icon_name(),
                title: format!("nixaudio · {output}"),
                description: snapshot.health.message.clone(),
                ..Default::default()
            }
        } else {
            ToolTip {
                icon_name: self.icon_name(),
                title: "nixaudio disconnected".into(),
                description: self
                    .error
                    .clone()
                    .unwrap_or_else(|| "Waiting for nixaudiod".into()),
                ..Default::default()
            }
        }
    }
    fn scroll(&mut self, delta: i32, _orientation: ksni::Orientation) {
        if let Some(output) = self
            .default_output()
            .filter(|output| output.location == "local")
        {
            let Some(current) = output.volume else {
                return;
            };
            let value = (current + if delta > 0 { 0.05 } else { -0.05 }).clamp(0.0, 1.5);
            let _ = self.actions.send(Action::Volume {
                object: output.id.clone(),
                value,
            });
        }
    }
    fn menu(&self) -> Vec<MenuItem<Self>> {
        let Some(snapshot) = &self.snapshot else {
            return vec![StandardItem {
                label: self
                    .error
                    .clone()
                    .unwrap_or_else(|| "Waiting for nixaudiod…".into()),
                enabled: false,
                ..Default::default()
            }
            .into()];
        };
        let mut menu = vec![
            StandardItem {
                label: format!("{} · {}", snapshot.host, snapshot.health.message),
                enabled: false,
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            self.output_menu(snapshot),
            self.input_menu(snapshot),
        ];
        if let Some(output) = self
            .default_output()
            .filter(|output| output.location == "local")
        {
            if let (Some(volume), Some(muted)) = (output.volume, output.muted) {
                menu.push(
                    SubMenu {
                        label: format!("Output volume · {}%", (volume * 100.0).round()),
                        submenu: Self::volume_actions(&output.id, volume, muted),
                        ..Default::default()
                    }
                    .into(),
                );
            }
        }
        menu.push(MenuItem::Separator);
        if snapshot.streams.is_empty() {
            menu.push(
                StandardItem {
                    label: "No active application streams".into(),
                    enabled: false,
                    ..Default::default()
                }
                .into(),
            );
        } else {
            menu.extend(
                snapshot
                    .streams
                    .iter()
                    .map(|stream| Self::stream_menu(stream, &snapshot.outputs)),
            );
        }
        if !snapshot.peers.is_empty() {
            menu.push(MenuItem::Separator);
            menu.push(
                SubMenu {
                    label: "Sharing circle".into(),
                    submenu: snapshot
                        .peers
                        .iter()
                        .map(|peer| {
                            StandardItem {
                                label: format!(
                                    "{} · {}",
                                    peer.name,
                                    if peer.available {
                                        "available"
                                    } else {
                                        "offline"
                                    }
                                ),
                                enabled: false,
                                ..Default::default()
                            }
                            .into()
                        })
                        .collect(),
                    ..Default::default()
                }
                .into(),
            );
        }
        menu
    }
}

async fn update_snapshot(handle: &ksni::Handle<AudioTray>, proxy: &AudioProxy<'_>) -> Result<()> {
    let json = proxy.inspect().await?;
    let snapshot: Snapshot = serde_json::from_str(&json).context("decode nixaudiod snapshot")?;
    handle
        .update(move |tray| {
            tray.snapshot = Some(snapshot);
            tray.error = None;
        })
        .await
        .context("tray stopped")?;
    Ok(())
}

async fn run_backend(
    handle: Arc<ksni::Handle<AudioTray>>,
    mut actions: mpsc::UnboundedReceiver<Action>,
) -> Result<()> {
    loop {
        let connection = match zbus::Connection::session().await {
            Ok(connection) => connection,
            Err(error) => {
                let _ = handle
                    .update(move |tray| {
                        tray.snapshot = None;
                        tray.error = Some(error.to_string());
                    })
                    .await;
                sleep(Duration::from_secs(2)).await;
                continue;
            }
        };
        let proxy = match AudioProxy::new(&connection).await {
            Ok(proxy) if proxy.api_version().await == Ok(API_VERSION) => proxy,
            Ok(_) => {
                let _ = handle
                    .update(|tray| {
                        tray.snapshot = None;
                        tray.error = Some("Unsupported nixaudiod API".into());
                    })
                    .await;
                sleep(Duration::from_secs(2)).await;
                continue;
            }
            Err(error) => {
                let _ = handle
                    .update(move |tray| {
                        tray.snapshot = None;
                        tray.error = Some(error.to_string());
                    })
                    .await;
                sleep(Duration::from_secs(2)).await;
                continue;
            }
        };
        if let Err(error) = update_snapshot(&handle, &proxy).await {
            let _ = handle
                .update(move |tray| {
                    tray.snapshot = None;
                    tray.error = Some(error.to_string());
                })
                .await;
            sleep(Duration::from_secs(2)).await;
            continue;
        }
        let mut changes = proxy.receive_changed().await?;
        loop {
            tokio::select! {
                change = changes.next() => {
                    if change.is_none() || update_snapshot(&handle, &proxy).await.is_err() { break; }
                }
                action = actions.recv() => {
                    let Some(action) = action else { return Ok(()) };
                    let result = match action {
                        Action::Route { stream, target, enabled } => {
                            let json = proxy.inspect().await?;
                            let snapshot: Snapshot = serde_json::from_str(&json)?;
                            // Amend the INTENT, not the effect. Reading `targets` here meant that
                            // ticking one remote output on a stream that was merely following the
                            // default pinned BOTH, and that ticking anything at all while a pinned
                            // peer was away replaced the pin with the fallback -- losing the route
                            // the user actually set, permanently and silently.
                            let mut targets: BTreeSet<String> = snapshot.streams.iter().find(|v| v.id == stream).map(|v| v.explicit_targets.iter().cloned().collect()).unwrap_or_default();
                            if enabled { targets.insert(target); } else { targets.remove(&target); }
                            if targets.is_empty() { proxy.clear_route(&stream).await } else { proxy.route(&stream, &targets.into_iter().collect::<Vec<_>>()).await }
                        }
                        Action::ClearRoute(stream) => proxy.clear_route(&stream).await,
                        Action::DefaultOutput(endpoint) => proxy.set_default_output(&endpoint).await,
                        Action::DefaultInput(endpoint) => proxy.set_default_input(&endpoint).await,
                        Action::Volume { object, value } => proxy.set_volume(&object, value).await,
                        Action::Muted { object, value } => proxy.set_muted(&object, value).await,
                    };
                    if let Err(error) = result { let message = error.to_string(); let _ = handle.update(move |tray| tray.error = Some(message)).await; }
                }
            }
        }
        let _ = handle
            .update(|tray| {
                tray.snapshot = None;
                tray.error = Some("nixaudiod disconnected".into());
            })
            .await;
        sleep(Duration::from_secs(2)).await;
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let (actions, receiver) = mpsc::unbounded_channel();
    let tray = AudioTray {
        snapshot: None,
        error: None,
        actions,
    };
    let handle = Arc::new(tray.spawn().await.context("register StatusNotifier tray")?);
    run_backend(handle, receiver).await
}
