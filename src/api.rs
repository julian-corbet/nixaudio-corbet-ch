#[zbus::proxy(
    interface = "ch.corbet.NixAudio1",
    default_service = "ch.corbet.NixAudio1",
    default_path = "/ch/corbet/NixAudio1"
)]
pub trait Audio {
    #[zbus(property)]
    fn api_version(&self) -> zbus::Result<u32>;
    fn inspect(&self) -> zbus::Result<String>;
    fn route(&self, stream: &str, targets: &[String]) -> zbus::Result<()>;
    fn clear_route(&self, stream: &str) -> zbus::Result<()>;
    fn set_default_output(&self, endpoint: &str) -> zbus::Result<()>;
    fn set_default_input(&self, endpoint: &str) -> zbus::Result<()>;
    fn set_volume(&self, object: &str, volume: f64) -> zbus::Result<()>;
    fn set_muted(&self, object: &str, muted: bool) -> zbus::Result<()>;
    #[zbus(signal)]
    fn changed(&self, revision: u64) -> zbus::Result<()>;
}
