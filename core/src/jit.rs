//! Enabling JIT for an app, by acting as its debugger.
//!
//! iOS lets a process that is being debugged run code it generates itself. Attaching a debugger
//! and letting go again used to be all it took. Since iOS 26, devices with the Trusted Execution
//! Monitor also want every executable region prepared through the debugger, so apps ask for
//! that with breakpoints: `brk #0xf00d`, with the request in x16 (0 = done, 1 = prepare the
//! region at x0 of x1 bytes, or allocate one when x0 is 0). The app-side half is described in
//! StikJIT's integration guide; this is the debugger's half.

use crate::{device, io};
use anyhow::{Result, anyhow, bail};
use idevice::{
    ReadWrite, RsdService, core_device::AppServiceClient, debug_proxy::DebugProxyClient,
};
use serde_json::json;
use std::collections::HashMap;
use std::time::Duration;

/// The breakpoint apps use to talk to the debugger.
const REQUEST_BREAKPOINT: u32 = 0xf00d;
const REQUEST_DETACH: u64 = 0;
const REQUEST_PREPARE_REGION: u64 = 1;
/// Register numbers in debugserver's replies.
const X0: u32 = 0x00;
const X1: u32 = 0x01;
const X16: u32 = 0x10;
const PC: u32 = 0x20;
const PAGE_SIZE: u64 = 0x4000;
/// How many page writes go out before reading the answers; a region can be thousands of pages.
const WRITES_PER_BATCH: usize = 128;
/// How long to wait for an app's first request. Apps that don't use the breakpoints never ask.
const FIRST_REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
/// How long to wait for more once an app has started asking.
const NEXT_REQUEST_TIMEOUT: Duration = Duration::from_secs(60);
const REPLY_TIMEOUT: Duration = Duration::from_secs(20);

/// Starts an app and enables JIT for it.
pub async fn enable(udid: &str, bundle_id: &str) -> Result<()> {
    io::log("Connecting to the device…");
    let mut tunnel = device::tunnel_for(Some(udid)).await?;
    // The debugger comes with the developer disk image, which a restart removes.
    if !crate::ddi::is_mounted(&tunnel) {
        crate::ddi::mount(&mut tunnel).await?;
        // The debugger shows up in a fresh list of services.
        tunnel = device::tunnel_for(Some(udid)).await?;
        if !crate::ddi::is_mounted(&tunnel) {
            anyhow::bail!(
                "The developer disk image is mounted, but the device still offers no debugger."
            );
        }
    }

    io::log("Starting the app…");
    let mut apps = AppServiceClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.services)
        .await
        .map_err(|e| anyhow!("Can't reach the device's app service: {e}"))?;
    // A fresh start: apps set up their JIT memory while they launch.
    let launched = tokio::time::timeout(
        REPLY_TIMEOUT,
        apps.launch_application(bundle_id, &[], true, false, None, None, None),
    )
    .await
    .map_err(|_| anyhow!("The app didn't start. Unlock the device and try again."))?
    .map_err(|e| anyhow!("Couldn't start the app: {e}"))?;

    io::log("Attaching the debugger…");
    let client = tokio::time::timeout(
        REPLY_TIMEOUT,
        DebugProxyClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.services),
    )
    .await
    .map_err(|_| anyhow!("The device's debugger didn't answer."))?
    .map_err(|e| anyhow!("Can't reach the device's debugger: {e}"))?;
    let mut debugger = Debugger { client };
    let regions = debugger.run(launched.pid).await?;

    match regions {
        Some(regions) => io::log(format!(
            "JIT is on. The app asked for {regions} memory region{}.",
            if regions == 1 { "" } else { "s" }
        )),
        None => io::log(
            "The debugger attached and let go. That turns JIT on for devices before iOS 26; \
             on newer ones the app has to ask for its memory, and this one didn't.",
        ),
    }
    io::emit(json!({ "event": "jit", "pid": launched.pid, "regions": regions }));
    Ok(())
}

struct Debugger {
    client: DebugProxyClient<Box<dyn ReadWrite>>,
}

/// Why the app stopped, from debugserver's `T` reply.
struct Stop {
    signal: String,
    thread: String,
    registers: HashMap<u32, u64>,
}

impl Debugger {
    /// Attaches, answers the app's requests and lets go. Returns how many regions the app
    /// asked for, or None when it never asked.
    async fn run(&mut self, pid: u32) -> Result<Option<usize>> {
        // Without acknowledgements every reply is one packet, which keeps waiting simple.
        if self.ask("QStartNoAckMode").await? == "OK" {
            self.client.set_ack_mode(false);
        }

        let attached = self.ask(&format!("vAttach;{pid:x}")).await?;
        if !attached.starts_with('T') {
            bail!(
                "The debugger couldn't attach ({attached}). The app has to be signed for \
                 development, which apps installed with Nimbus are."
            );
        }

        let mut regions = 0;
        let mut asked = false;
        let mut command = "c".to_string();
        loop {
            self.send(&command).await?;
            command = "c".to_string();
            let wait = if asked {
                NEXT_REQUEST_TIMEOUT
            } else {
                FIRST_REQUEST_TIMEOUT
            };
            let Ok(reply) = tokio::time::timeout(wait, self.reply()).await else {
                // Nothing more is coming: stop the app for a moment and let go of it.
                self.client.send_raw(&[0x03]).await?;
                let _ = tokio::time::timeout(REPLY_TIMEOUT, self.reply()).await;
                self.ask("D").await?;
                return Ok(asked.then_some(regions));
            };
            let reply = reply?;
            if reply.starts_with('W') || reply.starts_with('X') {
                bail!("The app quit while the debugger was attached.");
            }
            let Some(stop) = Stop::parse(&reply) else {
                continue;
            };
            let Some(pc) = stop.registers.get(&PC).copied() else {
                continue;
            };

            let instruction = self.read_u32(pc).await?;
            let is_request = instruction & 0xFFE0_001F == 0xD420_0000
                && (instruction >> 5) & 0xFFFF == REQUEST_BREAKPOINT;
            if !is_request {
                // Not for the debugger: hand the signal to the app, as if nobody was attached.
                command = format!("vCont;S{}:{}", stop.signal, stop.thread);
                continue;
            }
            asked = true;

            // Step over the breakpoint, or the app would hit it again.
            self.set_register(PC, pc + 4, &stop.thread).await?;
            let x0 = stop.registers.get(&X0).copied().unwrap_or(0);
            let x1 = stop.registers.get(&X1).copied().unwrap_or(0);
            match stop.registers.get(&X16).copied() {
                Some(REQUEST_DETACH) => {
                    self.ask("D").await?;
                    return Ok(Some(regions));
                }
                Some(REQUEST_PREPARE_REGION) if x0 != 0 || x1 != 0 => {
                    let address = self.prepare_region(x0, x1).await?;
                    self.set_register(X0, address, &stop.thread).await?;
                    regions += 1;
                    io::log(format!("Prepared a region of {} KB.", x1 / 1024));
                }
                _ => {}
            }
        }
    }

    /// Makes a region executable for the app, allocating it first when it has no address yet.
    /// Writing to a page through the debugger is what makes the device accept code in it.
    async fn prepare_region(&mut self, address: u64, length: u64) -> Result<u64> {
        let address = if address == 0 {
            let reply = self.ask(&format!("_M{length:x},rx")).await?;
            u64::from_str_radix(&reply, 16)
                .map_err(|_| anyhow!("The device didn't give the app memory ({reply})."))?
        } else {
            address
        };

        let pages: Vec<u64> = (0..length.div_ceil(PAGE_SIZE))
            .map(|page| address + page * PAGE_SIZE)
            .collect();
        for batch in pages.chunks(WRITES_PER_BATCH) {
            let mut packets = String::new();
            for page in batch {
                packets.push_str(&packet(&format!("M{page:x},1:69")));
            }
            self.client.send_raw(packets.as_bytes()).await?;
            for _ in batch {
                self.reply().await?;
            }
        }
        Ok(address)
    }

    async fn read_u32(&mut self, address: u64) -> Result<u32> {
        let reply = self.ask(&format!("m{address:x},4")).await?;
        little_endian(&reply)
            .map(|value| value as u32)
            .ok_or_else(|| anyhow!("Couldn't read the app's memory ({reply})."))
    }

    async fn set_register(&mut self, register: u32, value: u64, thread: &str) -> Result<()> {
        let bytes: String = value
            .to_le_bytes()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        self.ask(&format!("P{register:x}={bytes};thread:{thread};"))
            .await?;
        Ok(())
    }

    async fn ask(&mut self, command: &str) -> Result<String> {
        self.send(command).await?;
        tokio::time::timeout(REPLY_TIMEOUT, self.reply())
            .await
            .map_err(|_| anyhow!("The device's debugger stopped answering."))?
    }

    async fn send(&mut self, command: &str) -> Result<()> {
        self.client
            .send_raw(packet(command).as_bytes())
            .await
            .map_err(|e| anyhow!("Lost the connection to the debugger: {e}"))
    }

    async fn reply(&mut self) -> Result<String> {
        self.client
            .read_response()
            .await
            .map_err(|e| anyhow!("Lost the connection to the debugger: {e}"))?
            .ok_or_else(|| anyhow!("The device's debugger sent something unexpected."))
    }
}

impl Stop {
    /// Parses `T05thread:1a2b;00:…;10:…;20:…;`: a signal, then pairs of a name or register
    /// number and its value.
    fn parse(reply: &str) -> Option<Stop> {
        let rest = reply.strip_prefix('T')?;
        let signal = rest.get(..2)?.to_string();
        let mut thread = None;
        let mut registers = HashMap::new();
        for pair in rest.get(2..)?.split(';') {
            let Some((key, value)) = pair.split_once(':') else {
                continue;
            };
            if key == "thread" {
                thread = Some(value.to_string());
            } else if let (Ok(register), Some(value)) =
                (u32::from_str_radix(key, 16), little_endian(value))
            {
                // Names such as "metype" also parse as hex; register values are 8 bytes.
                if value_is_register(pair, key) {
                    registers.insert(register, value);
                }
            }
        }
        Some(Stop {
            signal,
            thread: thread?,
            registers,
        })
    }
}

/// Registers are written as two hex digits and sixteen for the value.
fn value_is_register(pair: &str, key: &str) -> bool {
    key.len() == 2 && pair.len() == key.len() + 1 + 16
}

/// Reads hex bytes in memory order as a number.
fn little_endian(hex: &str) -> Option<u64> {
    if hex.is_empty() || hex.len() > 16 || hex.len() % 2 != 0 {
        return None;
    }
    let mut value = 0u64;
    for index in (0..hex.len()).step_by(2).rev() {
        value = (value << 8) | u64::from(u8::from_str_radix(hex.get(index..index + 2)?, 16).ok()?);
    }
    Some(value)
}

/// Wraps a command the way debugserver expects it: `$command#checksum`.
fn packet(command: &str) -> String {
    let checksum = command
        .bytes()
        .fold(0u8, |sum, byte| sum.wrapping_add(byte));
    format!("${command}#{checksum:02x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packets_carry_their_checksum() {
        assert_eq!(packet("c"), "$c#63");
        assert_eq!(packet("QStartNoAckMode"), "$QStartNoAckMode#b0");
    }

    #[test]
    fn numbers_are_read_in_memory_order() {
        assert_eq!(little_endian("0df020d4"), Some(0xd420_f00d));
        assert_eq!(little_endian("0040000001000000"), Some(0x1_0000_4000));
        assert_eq!(little_endian("zz"), None);
        assert_eq!(little_endian(""), None);
    }

    #[test]
    fn stops_are_parsed() {
        let stop = Stop::parse(
            "T05thread:1a2b;00:0000000000000000;01:0000010000000000;10:0100000000000000;\
             20:0040000001000000;metype:6;threads:1a2b;",
        )
        .unwrap();
        assert_eq!(stop.signal, "05");
        assert_eq!(stop.thread, "1a2b");
        assert_eq!(stop.registers[&X0], 0);
        assert_eq!(stop.registers[&X1], 0x10000);
        assert_eq!(stop.registers[&X16], REQUEST_PREPARE_REGION);
        assert_eq!(stop.registers[&PC], 0x1_0000_4000);
        assert!(Stop::parse("W00").is_none());
    }

    #[test]
    fn the_request_breakpoint_is_recognised() {
        // brk #0xf00d
        let instruction = 0xD420_0000u32 | (REQUEST_BREAKPOINT << 5);
        assert_eq!(instruction & 0xFFE0_001F, 0xD420_0000);
        assert_eq!((instruction >> 5) & 0xFFFF, REQUEST_BREAKPOINT);
    }
}
