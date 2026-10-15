//! 本地 shell 目前工作目錄偵測(不靠 OSC 7)。
//!
//! Windows 的 cmd.exe / PowerShell 預設不送 OSC 7,所以檔案側窗的「跳至終端
//! 目前目錄」在本地分頁抓不到路徑。這裡直接讀 shell 子行程的真正 cwd:
//! Windows 讀 PEB(含往下找最深的後代,處理巢狀 shell / REPL),Linux 走
//! `/proc/<pid>/cwd`,其餘平台(macOS 等)回 `None`(沿用既有 OSC 7 行為)。

/// 讀本地 shell(`pid`)目前的工作目錄;抓不到回 `None`。
pub fn local_cwd(pid: u32) -> Option<String> {
    imp::local_cwd(pid)
}

/// shell(`pid`)底下還有沒有任何後代行程 = 前景還有程式在跑。
/// `None` = 這個平台判斷不出來(呼叫端要當成「可能還在」,不可據此做清理)。
pub fn has_descendants(pid: u32) -> Option<bool> {
    imp::has_descendants(pid)
}

#[cfg(windows)]
mod imp {
    use std::collections::{HashMap, HashSet};
    use windows_sys::Wdk::System::Threading::{NtQueryInformationProcess, ProcessBasicInformation};
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::Debug::ReadProcessMemory;
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_BASIC_INFORMATION, PROCESS_QUERY_INFORMATION, PROCESS_VM_READ,
    };

    // x64 固定偏移(PEB / RTL_USER_PROCESS_PARAMETERS 版面穩定):
    const PEB_PROCESS_PARAMETERS: usize = 0x20; // PEB->ProcessParameters
    const PARAMS_CURDIR_DOSPATH: usize = 0x38; // ->CurrentDirectory.DosPath(UNICODE_STRING)
    const UNICODE_STRING_BUFFER: usize = 0x08; // UNICODE_STRING.Buffer(相對 DosPath 起點)

    pub fn local_cwd(pid: u32) -> Option<String> {
        // 目標優先序:shell 的最深後代 → … → shell 本身。這樣「在巢狀 shell /
        // REPL 裡 cd」也抓得到目前目錄(前景行程通常是最深的後代)。
        for target in candidate_pids(pid) {
            if let Some(dir) = read_cwd(target) {
                return Some(dir);
            }
        }
        None
    }

    pub fn has_descendants(pid: u32) -> Option<bool> {
        // candidate_pids 墊底的是 shell 自己,長度 > 1 就代表底下還有後代。
        Some(candidate_pids(pid).len() > 1)
    }

    /// 由 shell pid 往下收集後代,依深度由深到淺排序,最後補上 shell 自己。
    fn candidate_pids(root: u32) -> Vec<u32> {
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        for (pid, ppid) in snapshot_parents() {
            children.entry(ppid).or_default().push(pid);
        }
        let mut out: Vec<(u32, u32)> = Vec::new(); // (depth, pid)
        let mut seen: HashSet<u32> = HashSet::new();
        seen.insert(root);
        let mut stack = vec![(0u32, root)];
        while let Some((depth, pid)) = stack.pop() {
            if depth > 0 {
                out.push((depth, pid));
            }
            if let Some(cs) = children.get(&pid) {
                for &c in cs {
                    if seen.insert(c) {
                        stack.push((depth + 1, c));
                    }
                }
            }
        }
        out.sort_by(|a, b| b.0.cmp(&a.0)); // 深度大在前
        let mut pids: Vec<u32> = out.into_iter().map(|(_, p)| p).collect();
        pids.push(root); // shell 本身墊底
        pids
    }

    /// 系統行程快照 → (pid, ppid) 清單。
    fn snapshot_parents() -> Vec<(u32, u32)> {
        let mut result = Vec::new();
        unsafe {
            let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snap == INVALID_HANDLE_VALUE || snap.is_null() {
                return result;
            }
            let mut entry: PROCESSENTRY32W = core::mem::zeroed();
            entry.dwSize = core::mem::size_of::<PROCESSENTRY32W>() as u32;
            if Process32FirstW(snap, &mut entry) != 0 {
                loop {
                    result.push((entry.th32ProcessID, entry.th32ParentProcessID));
                    if Process32NextW(snap, &mut entry) == 0 {
                        break;
                    }
                }
            }
            CloseHandle(snap);
        }
        result
    }

    fn read_cwd(pid: u32) -> Option<String> {
        unsafe {
            let h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, 0, pid);
            if h.is_null() {
                return None;
            }
            let dir = read_cwd_from_handle(h);
            CloseHandle(h);
            dir
        }
    }

    unsafe fn read_cwd_from_handle(h: HANDLE) -> Option<String> {
        let mut pbi: PROCESS_BASIC_INFORMATION = core::mem::zeroed();
        let status = NtQueryInformationProcess(
            h,
            ProcessBasicInformation,
            &mut pbi as *mut _ as *mut core::ffi::c_void,
            core::mem::size_of::<PROCESS_BASIC_INFORMATION>() as u32,
            core::ptr::null_mut(),
        );
        if status < 0 {
            return None; // NTSTATUS < 0 = 失敗
        }
        let peb = pbi.PebBaseAddress as usize;
        if peb == 0 {
            return None;
        }
        let params = read_ptr(h, peb + PEB_PROCESS_PARAMETERS)?;
        // CurrentDirectory.DosPath 是 UNICODE_STRING { u16 Length; u16 MaxLen; u32 pad; usize Buffer }
        let len = read_u16(h, params + PARAMS_CURDIR_DOSPATH)? as usize; // Length,bytes
        if len == 0 || len > 0x8000 {
            return None;
        }
        let buf_ptr = read_ptr(h, params + PARAMS_CURDIR_DOSPATH + UNICODE_STRING_BUFFER)?;
        if buf_ptr == 0 {
            return None;
        }
        let mut bytes = vec![0u8; len];
        if !read_exact(h, buf_ptr, &mut bytes) {
            return None;
        }
        let utf16: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        let mut s = String::from_utf16_lossy(&utf16);
        // cmd.exe 的 cwd 常帶尾端反斜線;去掉但保留磁碟根(如 `C:\`)。
        while s.len() > 3 && (s.ends_with('\\') || s.ends_with('/')) {
            s.pop();
        }
        if s.is_empty() {
            None
        } else {
            Some(s)
        }
    }

    unsafe fn read_exact(h: HANDLE, addr: usize, out: &mut [u8]) -> bool {
        let mut read = 0usize;
        ReadProcessMemory(
            h,
            addr as *const core::ffi::c_void,
            out.as_mut_ptr() as *mut core::ffi::c_void,
            out.len(),
            &mut read,
        ) != 0
            && read == out.len()
    }

    unsafe fn read_ptr(h: HANDLE, addr: usize) -> Option<usize> {
        let mut buf = [0u8; 8];
        if read_exact(h, addr, &mut buf) {
            Some(usize::from_le_bytes(buf))
        } else {
            None
        }
    }

    unsafe fn read_u16(h: HANDLE, addr: usize) -> Option<u16> {
        let mut buf = [0u8; 2];
        if read_exact(h, addr, &mut buf) {
            Some(u16::from_le_bytes(buf))
        } else {
            None
        }
    }
}

#[cfg(target_os = "linux")]
mod imp {
    pub fn local_cwd(pid: u32) -> Option<String> {
        std::fs::read_link(format!("/proc/{pid}/cwd"))
            .ok()
            .map(|p| p.to_string_lossy().into_owned())
    }

    /// 直接子行程就夠判斷(有後代必然有直接子行程)。`children` 需要核心的
    /// CONFIG_PROC_CHILDREN,讀不到就回 `None` 讓呼叫端當作「不確定」。
    pub fn has_descendants(pid: u32) -> Option<bool> {
        let children = std::fs::read_to_string(format!("/proc/{pid}/task/{pid}/children")).ok()?;
        Some(!children.trim().is_empty())
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod imp {
    pub fn local_cwd(_pid: u32) -> Option<String> {
        None
    }

    /// macOS 等平台要 libproc 才列得出後代,目前不支援(回 `None` = 不確定)。
    pub fn has_descendants(_pid: u32) -> Option<bool> {
        None
    }
}

#[cfg(all(test, any(windows, target_os = "linux")))]
mod tests {
    use super::{has_descendants, local_cwd};

    /// 讀「本行程」的 cwd 應等於 `std::env::current_dir()`(測試行程通常沒有
    /// 子行程,candidate 只剩自己)。這同時驗證 Windows 的 PEB 讀取路徑。
    #[test]
    fn reads_own_cwd() {
        let want = std::env::current_dir().unwrap();
        let pid = std::process::id();
        let got = local_cwd(pid).expect("應讀得到本行程 cwd");
        let norm = |s: &str| s.replace('\\', "/").trim_end_matches('/').to_lowercase();
        assert_eq!(norm(&got), norm(&want.to_string_lossy()));
    }

    /// 「前景還有沒有程式在跑」是自動復原卡住模式的唯一依據(見
    /// `Session::recover_stuck_modes`),兩個方向都要準:誤判成 false 會把
    /// 正在用滑鼠的 TUI 模式清掉,誤判成 true 則永遠救不回滾輪。
    #[test]
    fn has_descendants_tracks_child_lifetime() {
        let pid = std::process::id();
        assert_eq!(has_descendants(pid), Some(false), "一開始沒有子行程");

        #[cfg(windows)]
        let mut child = std::process::Command::new("cmd.exe")
            .args(["/c", "pause"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .spawn()
            .expect("spawn child");
        #[cfg(not(windows))]
        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("spawn child");

        assert_eq!(has_descendants(pid), Some(true), "子行程還在時要回 true");

        child.kill().expect("kill child");
        child.wait().expect("wait child");
        // 行程進表的更新不是同步的,給一點時間再判定。
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while has_descendants(pid) != Some(false) && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert_eq!(has_descendants(pid), Some(false), "子行程結束後要回 false");
    }
}
