//! Signal 1:1 CALL MEDIA bridge (presage side).
//!
//! Spawns and drives the standalone `signal_media --answer` engine (messaging/signal/calling/media)
//! for an INCOMING Signal voice call, and relays the RingRTC signaling both ways over the manager:
//!
//!   incoming Offer  --> decode ConnectionParametersV4 (call_media.rs)
//!                       generate our ephemeral X25519 private key + ICE ufrag/pwd
//!                       spawn signal_media --answer, feed START
//!                       engine reports PUB  -> send CallMessage Answer  (encode_answer_opaque)
//!                       engine reports CAND -> send CallMessage IceUpdate (encode_ice_opaque)
//!   incoming IceUpdate --> decode_ice_opaque -> feed the engine "RCAND <candidate>"
//!   incoming Hangup/Busy --> feed the engine "STOP" and reap it
//!
//! The engine does the X25519 DH + AEAD_AES_256_GCM SRTP keying + ICE + Opus + ALSA itself; this
//! side is pure signaling. Sends go through the command channel (Cmd::SendCall*) so the command loop
//! -- which owns the concrete Manager -- performs the actual manager.send_message.
//!
//! GATING: media auto-answer only kicks in when the flag file /media/internal/signal_call_media
//! exists, so normal incoming calls keep the signaling-only v1 behaviour (ring + missed-call) and
//! only a deliberate test auto-answers. See RUNTIME_STATUS.md.
//!
//! KNOWN LIVE-CALL UNKNOWN: the SRTP KDF binds caller_id/callee_id (RingRTC identity material) into
//! the HKDF info. Their exact bytes are unverified, so we currently pass EMPTY ids -- signaling and
//! ICE connectivity will work, but two-way audio needs those ids confirmed against a real call.
#![allow(dead_code)]

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Mutex, OnceLock};

use crate::structs::Cmd;
use presage::libsignal_service::prelude::Uuid;

/// The media engine binary on the device (patchelf'd to the wpe-glibc loader; see build-signal-media.sh).
const SIGNAL_MEDIA_BIN: &str = "/media/internal/signal_media_p";
/// Presence of this file enables auto-answer + media for incoming calls (test gate).
const MEDIA_GATE_FILE: &str = "/media/internal/signal_call_media";
const WPE_DIR: &str = "/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252";

/// Command sender, stashed from presage_rust_main, so a per-call reader thread can enqueue the
/// Answer/IceUpdate for the command loop (which owns the Manager) to send.
static CMD_TX: OnceLock<Mutex<Option<tokio::sync::mpsc::Sender<Cmd>>>> = OnceLock::new();

struct CallProc {
    child: Child,
    stdin: ChildStdin,
}
/// Active calls keyed by RingRTC call_id (in practice one at a time; keyed for safety).
static CALLS: OnceLock<Mutex<HashMap<u64, CallProc>>> = OnceLock::new();

fn calls() -> &'static Mutex<HashMap<u64, CallProc>> {
    CALLS.get_or_init(|| Mutex::new(HashMap::new()))
}
fn cmd_tx_slot() -> &'static Mutex<Option<tokio::sync::mpsc::Sender<Cmd>>> {
    CMD_TX.get_or_init(|| Mutex::new(None))
}

/// Called once from presage_rust_main with a clone of the command channel sender.
pub fn set_command_sender(tx: tokio::sync::mpsc::Sender<Cmd>) {
    *cmd_tx_slot().lock().unwrap() = Some(tx);
}

/// Enqueue a Cmd for the command loop. Called from a std reader thread (no async context), so
/// blocking_send is correct here.
fn enqueue(cmd: Cmd) {
    if let Some(tx) = cmd_tx_slot().lock().unwrap().as_ref() {
        let _ = tx.blocking_send(cmd);
    }
}

pub fn media_enabled() -> bool {
    std::path::Path::new(MEDIA_GATE_FILE).exists()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}
fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}
fn rand_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut buf);
    }
    buf
}
/// Random ICE token of `n` hex chars (a valid RFC5245 ice-char subset).
fn rand_token(n: usize) -> String {
    let s = hex(&rand_bytes(n.div_ceil(2)));
    s[..n].to_string()
}

/// Start (auto-answer) media for an incoming call. `caller_uuid` is who we send Answer/ICE back to.
///
/// `caller_id` / `callee_id` are the 32-byte RAW Curve25519 identity public keys bound into the
/// SRTP KDF (RingRTC negotiate_srtp_keys: caller = the offerer/remote peer's ACI identity key,
/// callee = our ACI identity key). Pass empty slices if unavailable -- signaling/ICE still work but
/// the SRTP keys won't match the peer, so there will be no audio.
pub fn start_incoming(
    caller_uuid: Uuid,
    call_id: u64,
    offer_opaque: &[u8],
    caller_id: &[u8],
    callee_id: &[u8],
) {
    if !media_enabled() {
        return;
    }
    let params = match crate::call_media::decode_offer_opaque(offer_opaque) {
        Some(p) => p,
        None => {
            eprintln!("call_bridge: could not decode offer opaque for call {call_id}");
            return;
        }
    };
    if caller_id.is_empty() || callee_id.is_empty() {
        eprintln!("call_bridge: WARNING starting call {call_id} without identity keys -> no audio (signaling/ICE only)");
    }

    let priv32 = rand_bytes(32);
    let our_ufrag = rand_token(4);
    let our_pwd = rand_token(24);

    // Capture the engine's stderr (gst/ICE/SRTP/ALSA logs) to a file so a live call is diagnosable;
    // fall back to null if the file can't be opened.
    let engine_log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/media/internal/sigmedia_call.log")
        .map(Stdio::from)
        .unwrap_or_else(|_| Stdio::null());
    let mut child = match Command::new(SIGNAL_MEDIA_BIN)
        .arg("--answer")
        // The engine inherits imlibpurpletransport's env (the correct wpe LD_LIBRARY_PATH incl.
        // /media/internal/sslfix where the GCM libsrtp2 lives); we only pin the gst plugin path +
        // a writable registry so it never rescans into a read-only location.
        .env("GST_PLUGIN_PATH", format!("{WPE_DIR}/lib/gstreamer-1.0"))
        .env("GST_REGISTRY", "/media/internal/gstreg-sig.bin")
        .env("GST_DEBUG", "2")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(engine_log)
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("call_bridge: failed to spawn {SIGNAL_MEDIA_BIN}: {e}");
            return;
        }
    };

    let mut stdin = match child.stdin.take() {
        Some(s) => s,
        None => return,
    };
    let stdout = match child.stdout.take() {
        Some(s) => s,
        None => return,
    };

    let start = format!(
        "START {} {} {} {} {} {} {} {}\n",
        hex(&priv32),
        hex(&params.public_key),
        hex(caller_id),
        hex(callee_id),
        our_ufrag,
        our_pwd,
        params.ice_ufrag,
        params.ice_pwd,
    );
    if let Err(e) = stdin.write_all(start.as_bytes()) {
        eprintln!("call_bridge: failed to write START: {e}");
        return;
    }
    let _ = stdin.flush();

    // Reader thread: turn the engine's PUB/CAND lines into outgoing CallMessages.
    let ufrag_c = our_ufrag.clone();
    let pwd_c = our_pwd.clone();
    std::thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => break,
            };
            if let Some(pubhex) = line.strip_prefix("PUB ") {
                if let Some(pk) = unhex(pubhex.trim()) {
                    let opaque = crate::call_media::encode_answer_opaque(&pk, &ufrag_c, &pwd_c);
                    enqueue(Cmd::SendCallAnswer { uuid: caller_uuid, call_id, opaque });
                }
            } else if let Some(cand) = line.strip_prefix("CAND ") {
                let opaque = crate::call_media::encode_ice_opaque(cand.trim());
                enqueue(Cmd::SendCallIce { uuid: caller_uuid, call_id, opaque });
            }
            // READY / AUDIOD / ERR: audiod is driven by call.c; just ignore here.
        }
    });

    calls().lock().unwrap().insert(call_id, CallProc { child, stdin });
}

/// Feed the engine one or more remote ICE candidates decoded from incoming IceUpdate opaques.
pub fn feed_remote_ice(call_id: u64, candidate_opaques: &[Vec<u8>]) {
    let mut guard = calls().lock().unwrap();
    if let Some(cp) = guard.get_mut(&call_id) {
        for op in candidate_opaques {
            if let Some(cand) = crate::call_media::decode_ice_opaque(op) {
                let _ = writeln!(cp.stdin, "RCAND {cand}");
            }
        }
        let _ = cp.stdin.flush();
    }
}

/// Tear down the engine for a call (hangup/busy).
pub fn stop(call_id: u64) {
    let cp = calls().lock().unwrap().remove(&call_id);
    if let Some(CallProc { mut child, mut stdin }) = cp {
        let _ = writeln!(stdin, "STOP");
        drop(stdin); // EOF -> engine leaves its stdin loop and calls signal_media_stop()
        // Reap off-thread so we never block the receive loop; kill as a backstop.
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(1500));
            let _ = child.kill();
            let _ = child.wait();
        });
    }
}
