//! Teleport: makes the device report a location of your choosing, through the Instruments
//! service Xcode uses to test locations. iOS keeps the location only while the connection
//! that set it stays open, so a task holds it open, apart from the engine's commands. The
//! device is back on its real location as soon as the task stops.

use crate::device;
use crate::io;
use anyhow::{Result, anyhow};
use idevice::RsdService;
use idevice::dvt::{
    location_simulation::LocationSimulationClient, remote_server::RemoteServerClient,
};
use serde_json::json;
use std::sync::Mutex;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// How often the location is set again, which keeps the connection from going idle.
const KEEP_ALIVE: Duration = Duration::from_secs(20);

enum Command {
    Move(f64, f64, oneshot::Sender<Result<()>>),
    Stop(oneshot::Sender<()>),
}

/// The task holding the location, while there is one.
static HOLDER: Mutex<Option<mpsc::Sender<Command>>> = Mutex::new(None);

fn holder() -> Option<mpsc::Sender<Command>> {
    let holder = HOLDER.lock().ok()?;
    holder.as_ref().filter(|sender| !sender.is_closed()).cloned()
}

fn check(latitude: f64, longitude: f64) -> Result<()> {
    if (-90.0..=90.0).contains(&latitude) && (-180.0..=180.0).contains(&longitude) {
        Ok(())
    } else {
        Err(anyhow!("That place isn't on Earth."))
    }
}

/// Moves the device to a place and keeps it there, until `stop` or until the connection is
/// lost. Moving again reuses the connection.
pub async fn teleport(udid: &str, latitude: f64, longitude: f64) -> Result<()> {
    check(latitude, longitude)?;
    if let Some(sender) = holder() {
        let (reply, answer) = oneshot::channel();
        if sender.send(Command::Move(latitude, longitude, reply)).await.is_ok()
            && let Ok(result) = answer.await
        {
            return result;
        }
    }
    let (sender, commands) = mpsc::channel(4);
    let (ready, started) = oneshot::channel();
    // Its own thread and runtime: the connection's futures can't move between threads, and
    // the engine's futures need a large stack.
    let udid = udid.to_string();
    std::thread::Builder::new()
        .name("nimbus-teleport-hold".to_string())
        .stack_size(16 * 1024 * 1024)
        .spawn(move || {
            match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                Ok(runtime) => runtime.block_on(hold(udid, latitude, longitude, commands, ready)),
                Err(e) => drop(ready.send(Err(anyhow!("Couldn't start Teleport: {e}")))),
            }
        })
        .map_err(|e| anyhow!("Couldn't start Teleport: {e}"))?;
    started
        .await
        .map_err(|_| anyhow!("Teleport stopped before it started."))??;
    if let Ok(mut holder) = HOLDER.lock() {
        *holder = Some(sender);
    }
    Ok(())
}

/// Puts the device back on its real location.
pub async fn stop() {
    let sender = HOLDER.lock().ok().and_then(|mut holder| holder.take());
    if let Some(sender) = sender {
        let (reply, done) = oneshot::channel();
        if sender.send(Command::Stop(reply)).await.is_ok() {
            let _ = tokio::time::timeout(Duration::from_secs(10), done).await;
        }
    }
}

/// Whether a location is being held right now.
pub fn is_active() -> bool {
    holder().is_some()
}

async fn hold(
    udid: String,
    latitude: f64,
    longitude: f64,
    mut commands: mpsc::Receiver<Command>,
    ready: oneshot::Sender<Result<()>>,
) {
    let mut tunnel = match device::tunnel_for(Some(&udid)).await {
        Ok(tunnel) => tunnel,
        Err(e) => return drop(ready.send(Err(e))),
    };
    // The Instruments service comes with the developer disk image, which a restart removes.
    if !crate::ddi::is_mounted(&tunnel) {
        if let Err(e) = crate::ddi::mount(&mut tunnel).await {
            return drop(ready.send(Err(e)));
        }
        tunnel = match device::tunnel_for(Some(&udid)).await {
            Ok(tunnel) => tunnel,
            Err(e) => return drop(ready.send(Err(e))),
        };
    }
    let mut server =
        match RemoteServerClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.services).await {
            Ok(server) => server,
            Err(e) => {
                let error = anyhow!("Can't reach the device's developer services: {e}");
                return drop(ready.send(Err(error)));
            }
        };
    server.read_message(0).await.ok();
    let mut location = match LocationSimulationClient::new(&mut server).await {
        Ok(location) => location,
        Err(e) => {
            let error = anyhow!("Can't reach the device's location service: {e}");
            return drop(ready.send(Err(error)));
        }
    };
    let (mut latitude, mut longitude) = (latitude, longitude);
    if let Err(e) = location.set(latitude, longitude).await {
        return drop(ready.send(Err(anyhow!("Couldn't set the location: {e}"))));
    }
    let _ = ready.send(Ok(()));

    loop {
        tokio::select! {
            command = commands.recv() => match command {
                Some(Command::Move(new_latitude, new_longitude, reply)) => {
                    let result = location
                        .set(new_latitude, new_longitude)
                        .await
                        .map_err(|e| anyhow!("Couldn't set the location: {e}"));
                    let failed = result.is_err();
                    if !failed {
                        (latitude, longitude) = (new_latitude, new_longitude);
                    }
                    let _ = reply.send(result);
                    if failed {
                        return;
                    }
                }
                Some(Command::Stop(reply)) => {
                    let _ = location.clear().await;
                    let _ = reply.send(());
                    return;
                }
                None => {
                    let _ = location.clear().await;
                    return;
                }
            },
            _ = tokio::time::sleep(KEEP_ALIVE) => {
                if location.set(latitude, longitude).await.is_err() {
                    // The connection is gone, and with it the location.
                    return;
                }
            }
        }
    }
}

/// For nimbus-helper: moves the device and holds it there until the helper is stopped.
pub async fn hold_until_stopped(udid: &str, latitude: &str, longitude: &str) -> Result<()> {
    let latitude: f64 = latitude
        .parse()
        .map_err(|_| anyhow!("That's not a latitude: {latitude}"))?;
    let longitude: f64 = longitude
        .parse()
        .map_err(|_| anyhow!("That's not a longitude: {longitude}"))?;
    teleport(udid, latitude, longitude).await?;
    io::emit(json!({ "event": "location", "latitude": latitude, "longitude": longitude }));
    while is_active() {
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Err(anyhow!("Lost the connection to the device, which is back on its real location."))
}
