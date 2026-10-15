//! tterm-session:一個「可運作的終端」= 資料來源 + 終端引擎。
//!
//! 資料來源目前有兩種:本地 PTY(`spawn_shell`)與無來源的合成資料
//! (`new_headless` + `demo_feed`,給效能驗證用);SSH 之後接同一個介面。
//!
//! 執行緒模型:背景 reader thread 把來源輸出餵進引擎(引擎在 `Mutex` 內),
//! UI thread 每 frame 取 damage / 拷貝 grid。引擎的 `PtyWrite` 事件
//! (DA/DSR 查詢回應)由 reader thread 直接回寫,不需上層介入。

mod proc_cwd;

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use tterm_ssh::{ShellEvent, ShellInput, SshTarget};

// 讓上層(FFI)不必直接相依 tterm-ssh 就能組出連線目標
pub use tterm_ssh::{Auth as SshAuth, SshTarget as SshConnectTarget};

/// 遠端操作逾時(連線多半已經半死)。UI 會給使用者看(見 tterm-ffi 的
/// error.rs),`op` 是穩定的代號:list_dir / home / read_file / write_file / exec。
#[derive(Debug, thiserror::Error)]
#[error("{op} timed out (the connection may be down)")]
pub struct Timeout {
    pub op: &'static str,
}
use tterm_term::demo::{self, DemoState};
use tterm_term::{modes, Damage, EngineEvent, TermEngine};

/// `recover_stuck_modes` 要連續幾次輪詢都判定「卡住」才真的復原。
/// UI 每 ~0.5s 問一次,兩次 = 最慢 1 秒內滾輪就會恢復。
const STUCK_POLLS_BEFORE_RESET: u32 = 2;

/// 跨執行緒共享的 session 狀態。
#[derive(Debug, Default)]
struct Shared {
    alive: AtomicBool,
    bell: AtomicU32,
    title: Mutex<String>,
    /// 程式經 OSC 52 設定的剪貼簿內容(tmux/vim 反白複製);UI 取走後寫入
    /// 系統剪貼簿。只保留最新一筆。
    clipboard: Mutex<Option<String>>,
    /// 連續幾次輪詢看到「模式卡住 + 沒有前景行程」(見 `recover_stuck_modes`)。
    stuck_polls: AtomicU32,
}

/// 平台預設 shell 的絕對路徑;None = 交給 portable_pty 的 `new_default_prog`。
///
/// Windows 上 `new_default_prog` 走 `%COMSPEC%`(cmd.exe),但使用者要的預設是
/// PowerShell:優先 PATH 上的 `pwsh.exe`(PowerShell 7),沒有就用系統內建的
/// `powershell.exe`。兩個都找不到才退回 cmd.exe。
/// Unix 維持 `$SHELL`,不動。
pub fn default_shell() -> Option<String> {
    #[cfg(windows)]
    {
        if let Some(p) = find_in_path("pwsh.exe") {
            return Some(p);
        }
        if let Some(p) = find_in_path("powershell.exe") {
            return Some(p);
        }
        // PATH 被改壞時仍找得到的固定位置
        let sysroot = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
        let builtin =
            std::path::PathBuf::from(sysroot).join(r"System32\WindowsPowerShell\v1.0\powershell.exe");
        if builtin.is_file() {
            return Some(builtin.to_string_lossy().into_owned());
        }
        None
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// 在 `PATH` 上找可執行檔,回傳絕對路徑。
#[cfg(windows)]
fn find_in_path(exe: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(exe))
        .find(|p| p.is_file())
        .map(|p| p.to_string_lossy().into_owned())
}

/// 讓 PowerShell 每次畫提示符時送 OSC 7 回報 cwd。
///
/// 必要性:PowerShell 的 `Set-Location` 只改 session 的 location,不動行程的
/// PEB cwd,所以 `proc_cwd`(讀子行程 PEB)那套對它完全無效——檔案側窗的
/// 「跳至終端目前目錄」會永遠停在啟動目錄。只能請 shell 自己回報。
/// 包住原本的 prompt(profile 自訂的也保留),失敗就當沒事。
#[cfg(windows)]
const PS_OSC7_HOOK: &str = r#"
$global:__tterm_prompt = $function:prompt
function global:prompt {
  try {
    $l = Get-Location
    if ($l.Provider.Name -eq 'FileSystem') {
      $p = $l.ProviderPath -replace '%','%25' -replace ' ','%20' -replace '\\','/'
      [Console]::Write("$([char]27)]7;file://$env:COMPUTERNAME/$p$([char]7)")
    }
  } catch { }
  if ($global:__tterm_prompt) { & $global:__tterm_prompt }
  else { "PS $((Get-Location).Path)> " }
}
"#;

/// PowerShell 的 `-Command` 在命令列上會被重新剖析(引號很容易被吃掉),
/// 改用 `-EncodedCommand`(UTF-16LE + base64)完全避開跳脫問題。
#[cfg(windows)]
fn encode_ps_command(script: &str) -> String {
    use base64::Engine;
    let utf16: Vec<u8> = script
        .encode_utf16()
        .flat_map(|u| u.to_le_bytes())
        .collect();
    base64::engine::general_purpose::STANDARD.encode(utf16)
}

/// `program` 為 None 時要開的東西:Windows 是帶 OSC 7 hook 的 PowerShell,
/// 其他平台交給 portable_pty(`$SHELL`)。
fn default_command() -> CommandBuilder {
    #[cfg(windows)]
    if let Some(shell) = default_shell() {
        let mut cmd = CommandBuilder::new(&shell);
        cmd.arg("-NoLogo");
        cmd.arg("-NoExit");
        cmd.arg("-EncodedCommand");
        cmd.arg(encode_ps_command(PS_OSC7_HOOK));
        return cmd;
    }
    CommandBuilder::new_default_prog()
}

struct PtyIo {
    master: Box<dyn MasterPty + Send>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    child: Mutex<Box<dyn Child + Send + Sync>>,
}

/// SSH 來源:tokio runtime 驅動連線的背景 task,input sender 送使用者輸入。
struct SshIo {
    // runtime 一定要活著,SSH channel 的背景 task 才會持續運作
    runtime: tokio::runtime::Runtime,
    // 保住 client(其 Handle 驅動傳輸;drop 會斷線;SFTP 也用它開 channel)。
    // Arc:exec 要 spawn 成 'static task(逾時只放棄等待、不取消)。
    client: Arc<tterm_ssh::SshClient>,
    input: tokio::sync::mpsc::Sender<ShellInput>,
    fingerprint: Option<String>,
    // 遠端檔案瀏覽(SFTP);第一次用到才建立
    sftp: tokio::sync::Mutex<Option<russh_sftp::client::SftpSession>>,
}

pub struct Session {
    engine: Arc<Mutex<TermEngine>>,
    shared: Arc<Shared>,
    io: Option<PtyIo>,
    ssh: Option<SshIo>,
    demo: DemoState,
}

impl Session {
    /// 無資料來源的 session(合成資料 / 測試用)。
    pub fn new_headless(cols: u16, rows: u16, scrollback: u32) -> Self {
        Self {
            engine: Arc::new(Mutex::new(TermEngine::new(
                cols as usize,
                rows as usize,
                scrollback as usize,
            ))),
            shared: Arc::new(Shared::default()),
            io: None,
            ssh: None,
            demo: DemoState::default(),
        }
    }

    /// 開一個本地 shell(Unix:`$SHELL`;Windows:ConPTY + PowerShell)。
    /// `program` 為 None 時用平台預設 shell(見 [`default_shell`])。
    pub fn spawn_shell(
        cols: u16,
        rows: u16,
        scrollback: u32,
        program: Option<&str>,
    ) -> Result<Self> {
        let pty = native_pty_system();
        let pair = pty
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("openpty")?;

        let mut cmd = match program {
            Some(p) => CommandBuilder::new(p),
            None => default_command(),
        };
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env("TERM_PROGRAM", "tterminal");
        if let Ok(dir) = std::env::current_dir() {
            cmd.cwd(dir);
        }

        let child = pair.slave.spawn_command(cmd).context("spawn shell")?;
        // Unix 上必須放掉 slave,否則 shell 結束時讀不到 EOF。
        drop(pair.slave);

        let reader = pair.master.try_clone_reader().context("clone reader")?;
        let writer = Arc::new(Mutex::new(pair.master.take_writer().context("take writer")?));

        let engine = Arc::new(Mutex::new(TermEngine::new(
            cols as usize,
            rows as usize,
            scrollback as usize,
        )));
        let shared = Arc::new(Shared::default());
        shared.alive.store(true, Ordering::Release);

        spawn_reader(reader, engine.clone(), shared.clone(), writer.clone());

        Ok(Self {
            engine,
            shared,
            io: Some(PtyIo {
                master: pair.master,
                writer,
                child: Mutex::new(child),
            }),
            ssh: None,
            demo: DemoState::default(),
        })
    }

    /// 連上 SSH server 並開互動 shell。連線與認證同步完成(阻塞),
    /// 之後由背景 tokio task 把 SSH 輸出餵進引擎、把使用者輸入送回。
    pub fn connect_ssh(
        target: SshTarget,
        cols: u16,
        rows: u16,
        scrollback: u32,
    ) -> Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .context("build tokio runtime")?;

        let (client, shell) = runtime.block_on(async {
            let client = tterm_ssh::connect(&target).await?;
            let shell = client.open_shell(cols, rows, "xterm-256color").await?;
            Ok::<_, anyhow::Error>((client, shell))
        })?;
        let fingerprint = client.host_key_fingerprint().map(|s| s.to_string());

        let engine = Arc::new(Mutex::new(TermEngine::new(
            cols as usize,
            rows as usize,
            scrollback as usize,
        )));
        let shared = Arc::new(Shared::default());
        shared.alive.store(true, Ordering::Release);

        // 背景 task:SSH 輸出 → 引擎;引擎的 PtyWrite 回應 → SSH input。
        let tterm_ssh::Shell {
            input,
            mut events,
        } = shell;
        let reply_tx = input.clone();
        let engine_bg = engine.clone();
        let shared_bg = shared.clone();
        runtime.spawn(async move {
            while let Some(ev) = events.recv().await {
                match ev {
                    ShellEvent::Data(bytes) => {
                        // 鎖只在同步區塊內持有,不跨 .await
                        let out = {
                            let mut e = engine_bg.lock().unwrap();
                            e.feed(&bytes);
                            e.drain_events()
                        };
                        for evt in out {
                            match evt {
                                EngineEvent::PtyWrite(b) => {
                                    let _ = reply_tx.send(ShellInput::Data(b)).await;
                                }
                                EngineEvent::Title(t) => {
                                    *shared_bg.title.lock().unwrap() = t;
                                }
                                EngineEvent::ResetTitle => {
                                    shared_bg.title.lock().unwrap().clear();
                                }
                                EngineEvent::Bell => {
                                    shared_bg.bell.fetch_add(1, Ordering::Relaxed);
                                }
                                EngineEvent::ClipboardStore(_, text) => {
                                    if !text.is_empty() {
                                        *shared_bg.clipboard.lock().unwrap() = Some(text);
                                    }
                                }
                            }
                        }
                    }
                    ShellEvent::ExitStatus(_) => {}
                    ShellEvent::Closed => break,
                }
            }
            shared_bg.alive.store(false, Ordering::Release);
        });

        Ok(Self {
            engine,
            shared,
            io: None,
            ssh: Some(SshIo {
                runtime,
                client: Arc::new(client),
                input,
                fingerprint,
                sftp: tokio::sync::Mutex::new(None),
            }),
            demo: DemoState::default(),
        })
    }

    /// SSH host key 指紋(`SHA256:...`);本地 shell session 回 None。
    pub fn ssh_fingerprint(&self) -> Option<&str> {
        self.ssh.as_ref().and_then(|s| s.fingerprint.as_deref())
    }

    /// 這是不是 SSH session(決定檔案側窗走遠端 SFTP 還是本地)。
    pub fn is_ssh(&self) -> bool {
        self.ssh.is_some()
    }

    /// SFTP 操作的逾時。呼叫端(UI thread)是同步 block:沒有逾時的話,
    /// 連線半死(網路黑洞)時整個視窗會 no response 直到 TCP 層放棄。
    /// 逾時後把快取的 SFTP session 丟掉,下次操作重開一條。
    const SFTP_META_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);
    const SFTP_DATA_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

    fn sftp_op<T>(
        &self,
        timeout: std::time::Duration,
        what: &'static str,
        op: impl AsyncFnOnce(&russh_sftp::client::SftpSession) -> Result<T>,
    ) -> Result<T> {
        let ssh = self.ssh.as_ref().context("not an SSH session")?;
        let result = ssh.runtime.block_on(async {
            tokio::time::timeout(timeout, async {
                let mut guard = ssh.sftp.lock().await;
                if guard.is_none() {
                    *guard = Some(ssh.client.open_sftp().await?);
                }
                op(guard.as_ref().unwrap()).await
            })
            .await
        });
        match result {
            Ok(inner) => inner,
            Err(_) => {
                // 逾時:被中斷的操作可能把 SFTP session 弄壞,丟掉重來
                ssh.runtime.block_on(async { *ssh.sftp.lock().await = None });
                Err(Timeout { op: what }.into())
            }
        }
    }

    /// 遠端目錄列表(SFTP)。
    pub fn sftp_list(&self, path: &str) -> Result<Vec<tterm_ssh::SftpEntry>> {
        self.sftp_op(Self::SFTP_META_TIMEOUT, "list_dir", async |sftp| {
            let mut out = Vec::new();
            for entry in sftp.read_dir(path).await.context("read_dir")? {
                let meta = entry.metadata();
                out.push(tterm_ssh::SftpEntry {
                    name: entry.file_name(),
                    is_dir: meta.is_dir(),
                    size: meta.size.unwrap_or(0),
                });
            }
            Ok(out)
        })
    }

    /// 遠端 home 目錄(canonicalize ".")。
    pub fn sftp_home(&self) -> Result<String> {
        self.sftp_op(Self::SFTP_META_TIMEOUT, "home", async |sftp| {
            sftp.canonicalize(".").await.context("canonicalize")
        })
    }

    /// 讀遠端檔案。
    pub fn sftp_read(&self, path: &str) -> Result<Vec<u8>> {
        self.sftp_op(Self::SFTP_DATA_TIMEOUT, "read_file", async |sftp| {
            sftp.read(path).await.context("sftp read")
        })
    }

    /// 寫遠端檔案(覆寫)。
    pub fn sftp_write(&self, path: &str, data: &[u8]) -> Result<()> {
        self.sftp_op(Self::SFTP_DATA_TIMEOUT, "write_file", async |sftp| {
            tterm_ssh::sftp_write_all(sftp, path, data).await
        })
    }

    /// 在遠端執行命令(獨立 exec channel),回傳 stdout;逾時回錯誤。
    /// 用途:偵測 shell 目前的工作目錄(含 tmux 內)——命令用 `sh -s`、
    /// 腳本走 stdin,不受登入 shell(zsh/fish)影響。
    ///
    /// 逾時是「放棄等待」不是「取消」:exec task detach 後在背景跑完、
    /// 正常關 channel。中途取消會把 channel 留在半開狀態,連按幾次就把
    /// server 的 MaxSessions 吃光,russh 收到對不上號的回覆還可能整條
    /// 連線出錯(tab 直接變已結束)。
    pub fn ssh_exec(
        &self,
        cmd: &str,
        stdin: &[u8],
        timeout: std::time::Duration,
    ) -> Result<Vec<u8>> {
        let ssh = self.ssh.as_ref().context("not an SSH session")?;
        let client = ssh.client.clone();
        let cmd = cmd.to_string();
        let stdin = stdin.to_vec();
        ssh.runtime.block_on(async {
            let task = tokio::spawn(async move { client.exec(&cmd, &stdin).await });
            match tokio::time::timeout(timeout, task).await {
                Ok(joined) => joined.context("exec task")?,
                Err(_) => Err(Timeout { op: "exec" }.into()), // task 續跑至完成
            }
        })
    }

    /// 使用者輸入 → 資料來源。與一般終端一致:有輸入就跳回最新輸出。
    pub fn write(&self, bytes: &[u8]) -> Result<()> {
        self.engine.lock().unwrap().scroll_to_bottom();
        if let Some(io) = &self.io {
            let mut w = io.writer.lock().unwrap();
            w.write_all(bytes).context("write to pty")?;
            w.flush().context("flush pty")?;
        } else if let Some(ssh) = &self.ssh {
            // blocking_send:呼叫端是非 runtime 執行緒,安全阻塞直到有空間
            ssh.input
                .blocking_send(ShellInput::Data(bytes.to_vec()))
                .map_err(|_| anyhow::anyhow!("SSH connection closed"))?;
        }
        Ok(())
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        self.engine
            .lock()
            .unwrap()
            .resize(cols as usize, rows as usize);
        if let Some(io) = &self.io {
            io.master
                .resize(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                })
                .context("resize pty")?;
        } else if let Some(ssh) = &self.ssh {
            let _ = ssh.input.blocking_send(ShellInput::Resize { cols, rows });
        }
        Ok(())
    }

    /// 存取引擎(短時間持鎖;渲染執行緒每 frame 呼叫)。
    pub fn with_engine<R>(&self, f: impl FnOnce(&mut TermEngine) -> R) -> R {
        f(&mut self.engine.lock().unwrap())
    }

    pub fn take_damage(&self) -> Damage {
        self.engine.lock().unwrap().take_damage()
    }

    pub fn fill_grid_u32(&self, out: &mut [u32]) -> usize {
        self.engine.lock().unwrap().fill_grid_u32(out)
    }

    pub fn mode_bits(&self) -> u32 {
        self.engine.lock().unwrap().mode_bits()
    }

    pub fn cursor(&self) -> (usize, usize, bool) {
        let e = self.engine.lock().unwrap();
        let (row, col) = e.cursor_position();
        (row, col, e.cursor_visible())
    }

    pub fn scroll_display(&self, delta: i32) {
        self.engine.lock().unwrap().scroll_display(delta);
    }

    pub fn visible_text(&self) -> Vec<String> {
        self.engine.lock().unwrap().visible_text()
    }

    pub fn title(&self) -> String {
        self.shared.title.lock().unwrap().clone()
    }

    /// 最近一次 OSC 7 回報的工作目錄(shell 有送才有值)。
    pub fn current_directory(&self) -> Option<String> {
        self.engine
            .lock()
            .unwrap()
            .current_directory()
            .map(|s| s.to_string())
    }

    /// 本地 shell 目前的工作目錄,直接讀子行程(不靠 OSC 7)。
    /// 用在 Windows 的 cmd.exe / PowerShell 不送 OSC 7 時的「跳至終端目前
    /// 目錄」。SSH session 或抓不到時回 `None`。
    pub fn local_cwd(&self) -> Option<String> {
        let io = self.io.as_ref()?;
        let pid = io.child.lock().unwrap().process_id()?;
        proc_cwd::local_cwd(pid)
    }

    /// 手動把終端拉回一般狀態(離開 alt screen、關滑鼠回報、顯示游標)。
    /// 對應 UI 上的「重設終端」——TUI 被中斷後滾輪失效時的自救出口。
    pub fn reset_input_modes(&self) {
        self.engine.lock().unwrap().reset_input_modes();
    }

    /// 自動復原卡住的終端模式:留著 alt screen / 滑鼠回報,shell 底下卻已經
    /// 沒有任何後代行程 → 設這些模式的 TUI 早就死了(Ctrl+C / crash / kill
    /// 都不會送復原序列),沒人會來收拾,這裡替它關掉。回傳是否真的清了。
    ///
    /// 只對本地 shell 有效(SSH 看不到遠端的行程樹),平台判斷不出後代時
    /// (macOS)一律不動——寧可讓使用者按「重設終端」,也不能誤殺正在用
    /// 滑鼠的前景程式。
    pub fn recover_stuck_modes(&self) -> bool {
        let clear = |ret: bool| {
            self.shared.stuck_polls.store(0, Ordering::Relaxed);
            ret
        };
        let Some(io) = self.io.as_ref() else {
            return clear(false);
        };
        if self.engine.lock().unwrap().mode_bits() & modes::WHEEL_BLOCKING == 0 {
            return clear(false);
        }
        let Some(pid) = io.child.lock().unwrap().process_id() else {
            return clear(false);
        };
        if proc_cwd::has_descendants(pid) != Some(false) {
            return clear(false); // 還有前景程式,或這個平台判斷不出來
        }
        // 要連續兩次輪詢都成立才動手:單次觀察會誤殺「前一個 TUI 剛結束、
        // 下一個剛啟動」這個空隙裡設好模式的新程式。
        if self.shared.stuck_polls.fetch_add(1, Ordering::Relaxed) < STUCK_POLLS_BEFORE_RESET - 1 {
            return false;
        }
        self.engine.lock().unwrap().reset_input_modes();
        clear(true)
    }

    pub fn bell_count(&self) -> u32 {
        self.shared.bell.load(Ordering::Relaxed)
    }

    /// 取走 OSC 52 設定的剪貼簿內容;沒有新內容回 `Ok(None)`。
    /// 內容長度 > `cap` 時**不取走**、回 `Err(所需長度)`(呼叫端擴大 buffer
    /// 重呼叫,重呼叫才會取走——取走是唯一的消費點,不能因 buffer 不夠而丟失)。
    pub fn take_clipboard(&self, cap: usize) -> Result<Option<String>, usize> {
        let mut guard = self.shared.clipboard.lock().unwrap();
        match guard.as_ref() {
            None => Ok(None),
            Some(t) if t.len() > cap => Err(t.len()),
            Some(_) => Ok(guard.take()),
        }
    }

    /// 來源是否還活著(PTY 尚未 EOF)。headless session 永遠回 false。
    pub fn is_alive(&self) -> bool {
        self.shared.alive.load(Ordering::Acquire)
    }

    /// 餵入合成資料流(效能驗證用,不經過來源)。
    pub fn demo_feed(&mut self, scenario: u32, nbytes: usize) -> usize {
        let size = self.engine.lock().unwrap().size();
        let data = demo::gen_chunk(scenario, &mut self.demo, nbytes, size.cols, size.rows);
        let mut e = self.engine.lock().unwrap();
        e.feed(&data);
        let _ = e.drain_events();
        data.len()
    }

    /// 等子行程結束(測試用)。
    pub fn wait_for_exit(&self, timeout: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        while std::time::Instant::now() < deadline {
            if !self.is_alive() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        false
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Some(io) = &self.io {
            let _ = io.child.lock().unwrap().kill();
        }
    }
}

fn spawn_reader(
    mut reader: Box<dyn Read + Send>,
    engine: Arc<Mutex<TermEngine>>,
    shared: Arc<Shared>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
) {
    std::thread::Builder::new()
        .name("tterm-pty-reader".into())
        .spawn(move || {
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                let n = match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                let events = {
                    let mut e = engine.lock().unwrap();
                    e.feed(&buf[..n]);
                    e.drain_events()
                };
                for ev in events {
                    match ev {
                        // 終端能力查詢的回應必須回寫,否則 vim/htop 會卡住或降級
                        EngineEvent::PtyWrite(bytes) => {
                            let mut w = writer.lock().unwrap();
                            let _ = w.write_all(&bytes);
                            let _ = w.flush();
                        }
                        EngineEvent::Title(t) => *shared.title.lock().unwrap() = t,
                        EngineEvent::ResetTitle => shared.title.lock().unwrap().clear(),
                        EngineEvent::Bell => {
                            shared.bell.fetch_add(1, Ordering::Relaxed);
                        }
                        EngineEvent::ClipboardStore(_, text) => {
                            if !text.is_empty() {
                                *shared.clipboard.lock().unwrap() = Some(text);
                            }
                        }
                    }
                }
            }
            shared.alive.store(false, Ordering::Release);
        })
        .expect("spawn pty reader thread");
}
