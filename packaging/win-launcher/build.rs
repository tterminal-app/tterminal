//! 把 Flutter bundle 的 zip 嵌進執行檔。
//!
//! `TTERM_PAYLOAD` 指向要嵌入的 zip;未設定時嵌入空 payload,
//! 讓 crate 在沒有 bundle 的環境下仍可編譯與跑測試。

use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=TTERM_PAYLOAD");

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let dest = out_dir.join("payload.zip");
    let payload = std::env::var("TTERM_PAYLOAD").unwrap_or_default();

    let bytes = if payload.is_empty() {
        Vec::new()
    } else {
        let src = Path::new(&payload);
        println!("cargo:rerun-if-changed={}", src.display());
        std::fs::read(src)
            .unwrap_or_else(|e| panic!("讀取 TTERM_PAYLOAD {}: {e}", src.display()))
    };

    // 內容雜湊當版本識別:payload 換了就解壓到新目錄,自然支援升級
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in &bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    println!("cargo:rustc-env=TTERM_PAYLOAD_HASH={hash:016x}");
    println!("cargo:rustc-env=TTERM_PAYLOAD_LEN={}", bytes.len());

    std::fs::write(&dest, &bytes).expect("寫入 payload.zip");
}
