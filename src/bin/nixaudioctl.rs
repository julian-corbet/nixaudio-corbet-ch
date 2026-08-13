use anyhow::{bail, Context, Result};
use nixaudio::api::AudioProxy;

fn usage() -> ! {
    eprintln!("usage:\n  nixaudioctl inspect\n  nixaudioctl route STREAM OUTPUT [OUTPUT...]\n  nixaudioctl clear-route STREAM\n  nixaudioctl default-output OUTPUT\n  nixaudioctl default-input INPUT\n  nixaudioctl volume OBJECT 0.0..1.5\n  nixaudioctl mute OBJECT on|off");
    std::process::exit(2)
}

#[tokio::main]
async fn main() -> Result<()> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.is_empty() {
        usage();
    }
    let connection = zbus::Connection::session()
        .await
        .context("connect to the session D-Bus")?;
    let proxy = AudioProxy::new(&connection)
        .await
        .context("connect to nixaudiod")?;
    match arguments[0].as_str() {
        "inspect" if arguments.len() == 1 => println!("{}", proxy.inspect().await?),
        "route" if arguments.len() >= 3 => proxy.route(&arguments[1], &arguments[2..]).await?,
        "clear-route" if arguments.len() == 2 => proxy.clear_route(&arguments[1]).await?,
        "default-output" if arguments.len() == 2 => proxy.set_default_output(&arguments[1]).await?,
        "default-input" if arguments.len() == 2 => proxy.set_default_input(&arguments[1]).await?,
        "volume" if arguments.len() == 3 => {
            let volume: f64 = arguments[2].parse().context("volume must be a number")?;
            proxy.set_volume(&arguments[1], volume).await?;
        }
        "mute" if arguments.len() == 3 => {
            let muted = match arguments[2].as_str() {
                "on" | "true" | "1" => true,
                "off" | "false" | "0" => false,
                _ => bail!("mute must be on or off"),
            };
            proxy.set_muted(&arguments[1], muted).await?;
        }
        _ => usage(),
    }
    Ok(())
}
