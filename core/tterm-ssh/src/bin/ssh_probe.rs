//! ssh_probe:SSH → TermEngine 端對端驗證。
//!
//! 連上 SSH server、開 shell、跑指令,把輸出經過終端引擎後印出最終畫面。
//! 環境變數:TTERM_PROBE_HOST(預設 127.0.0.1)、TTERM_PROBE_PORT(2222)、
//! TTERM_PROBE_USER、TTERM_PROBE_PASS。

use std::time::Duration;

use anyhow::{bail, Result};
use tterm_ssh::{connect, Auth, ShellEvent, ShellInput, SshTarget};
use tterm_term::{EngineEvent, TermEngine};

#[tokio::main]
async fn main() -> Result<()> {
    let host = std::env::var("TTERM_PROBE_HOST").unwrap_or_else(|_| "127.0.0.1".into());
    let port: u16 = std::env::var("TTERM_PROBE_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(2222);
    let username = std::env::var("TTERM_PROBE_USER").expect("TTERM_PROBE_USER not set");
    let password = std::env::var("TTERM_PROBE_PASS").expect("TTERM_PROBE_PASS not set");

    let target = SshTarget {
        host,
        port,
        username,
        auth: Auth::Password(password),
        expected_fingerprint: None,
    };

    eprintln!("[probe] connecting {}:{} ...", target.host, target.port);
    let client = connect(&target).await?;
    let mut shell = client.open_shell(100, 30, "xterm-256color").await?;
    let mut engine = TermEngine::new(100, 30, 5000);

    shell
        .input
        .send(ShellInput::Data(
            b"echo PROBE-$((6*7)); uname -sm; exit\n".to_vec(),
        ))
        .await?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
    loop {
        match tokio::time::timeout_at(deadline, shell.events.recv()).await {
            Ok(Some(ShellEvent::Data(data))) => {
                engine.feed(&data);
                for ev in engine.drain_events() {
                    if let EngineEvent::PtyWrite(bytes) = ev {
                        let _ = shell.input.send(ShellInput::Data(bytes)).await;
                    }
                }
            }
            Ok(Some(ShellEvent::ExitStatus(code))) => {
                eprintln!("[probe] remote exit status: {code}");
            }
            Ok(Some(ShellEvent::Closed)) | Ok(None) => break,
            Err(_) => {
                eprintln!("[probe] timeout waiting for shell output");
                break;
            }
        }
    }

    let screen = engine.visible_text().join("\n");
    println!("---- terminal screen ----");
    println!("{}", screen.trim_end());
    println!("-------------------------");

    let _ = client.disconnect().await;

    if screen.contains("PROBE-42") {
        println!("SSH-PROBE-OK");
        Ok(())
    } else {
        bail!("PROBE-42 not found in terminal output");
    }
}
