//! tterminal 單檔啟動器。
//!
//! Flutter 的 Windows 產物是一個資料夾(exe + DLL + data/),不是單一檔案。
//! 這個啟動器把整份 bundle 壓成 zip 嵌進自己,執行時解壓到
//! `%LOCALAPPDATA%\tterminal\app-<payload 雜湊>` 再啟動真正的 exe。
//!
//! * 解壓只發生一次:目錄裡有完成標記就直接啟動(冷啟動後幾乎無成本)。
//! * payload 換版本 → 雜湊改變 → 解壓到新目錄,舊版自動不再使用。
//! * 命令列參數原樣傳給 app。
//!
//! 只有「找路徑 + 啟動」是平台相關的;解壓邏輯是跨平台的,以便在 Linux 上測試。

#![cfg_attr(windows, windows_subsystem = "windows")]

use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};

/// 內嵌的 Flutter bundle(build.rs 產生;未提供 payload 時為空)。
static PAYLOAD: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/payload.zip"));

const PAYLOAD_HASH: &str = env!("TTERM_PAYLOAD_HASH");

/// 真正的 Flutter 執行檔名。非 Windows 的分支只為了能在開發機上端對端測試。
#[cfg(windows)]
const APP_EXE: &str = "tterm_app.exe";
#[cfg(not(windows))]
const APP_EXE: &str = "tterm_app";
const COMPLETE_MARKER: &str = ".tterm-extract-complete";

fn main() {
    if let Err(msg) = run() {
        report_error(&msg);
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    if PAYLOAD.is_empty() {
        return Err(
            "這個執行檔在建置時沒有嵌入應用程式內容。\n\
             請用 scripts/build-windows.ps1 重新打包。"
                .into(),
        );
    }

    let dir = install_dir()?;
    if !dir.join(COMPLETE_MARKER).exists() {
        extract_payload(PAYLOAD, &dir).map_err(|e| format!("解壓縮失敗:{e}"))?;
        std::fs::write(dir.join(COMPLETE_MARKER), PAYLOAD_HASH)
            .map_err(|e| format!("寫入完成標記失敗:{e}"))?;
    }

    let exe = dir.join(APP_EXE);
    if !exe.exists() {
        return Err(format!("解壓後找不到 {APP_EXE}(位置:{})", dir.display()));
    }
    launch(&exe, &dir)
}

/// `%LOCALAPPDATA%\tterminal\app-<hash>`(非 Windows 用 XDG 快取目錄,供測試)。
fn install_dir() -> Result<PathBuf, String> {
    let base = if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .ok_or("找不到 LOCALAPPDATA 環境變數")?
    } else {
        std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
            .ok_or("找不到快取目錄")?
    };
    let dir = base.join("tterminal").join(format!("app-{PAYLOAD_HASH}"));
    std::fs::create_dir_all(&dir).map_err(|e| format!("建立 {}:{e}", dir.display()))?;
    Ok(dir)
}

/// 解壓 zip 到 `dest`。會擋掉 zip slip(路徑逃逸)。
fn extract_payload(payload: &[u8], dest: &Path) -> std::io::Result<()> {
    let mut archive = zip::ZipArchive::new(Cursor::new(payload))?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        // enclosed_name 會拒絕 `..` 與絕對路徑
        let Some(rel) = entry.enclosed_name() else {
            continue;
        };
        let out = dest.join(rel);
        if entry.is_dir() {
            std::fs::create_dir_all(&out)?;
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut buf = Vec::with_capacity(entry.size() as usize);
        entry.read_to_end(&mut buf)?;
        std::fs::write(&out, buf)?;

        // Windows 不看 unix 權限;非 Windows 要把執行權限帶回來
        #[cfg(unix)]
        if let Some(mode) = entry.unix_mode() {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&out, std::fs::Permissions::from_mode(mode))?;
        }
    }
    Ok(())
}

fn launch(exe: &Path, workdir: &Path) -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::Command::new(exe)
        .args(&args)
        .current_dir(workdir)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("無法啟動 {}:{e}", exe.display()))
}

#[cfg(windows)]
fn report_error(msg: &str) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK};

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            wide(msg).as_ptr(),
            wide("tterminal").as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

#[cfg(not(windows))]
fn report_error(msg: &str) {
    eprintln!("tterminal: {msg}");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn make_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut buf = Cursor::new(Vec::new());
        {
            let mut w = zip::ZipWriter::new(&mut buf);
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            for (name, data) in entries {
                w.start_file(*name, opts).unwrap();
                w.write_all(data).unwrap();
            }
            w.finish().unwrap();
        }
        buf.into_inner()
    }

    #[test]
    fn extracts_nested_files() {
        let zip = make_zip(&[
            ("tterm_app.exe", b"MZfake"),
            ("data/flutter_assets/asset.bin", b"asset-bytes"),
        ]);
        let dir = std::env::temp_dir().join(format!("tterm-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        extract_payload(&zip, &dir).unwrap();

        assert_eq!(std::fs::read(dir.join("tterm_app.exe")).unwrap(), b"MZfake");
        assert_eq!(
            std::fs::read(dir.join("data/flutter_assets/asset.bin")).unwrap(),
            b"asset-bytes"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rejects_path_traversal() {
        // 惡意 zip 想寫到解壓目錄之外
        let zip = make_zip(&[("../escaped.txt", b"nope")]);
        let dir = std::env::temp_dir().join(format!("tterm-test-esc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        extract_payload(&zip, &dir).unwrap();

        assert!(
            !dir.parent().unwrap().join("escaped.txt").exists(),
            "路徑逃逸的檔案不該被寫出"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
