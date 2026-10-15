//! term_bench:終端引擎吞吐量基準。
//!
//! 用法:`cargo run --release --bin term_bench [MiB] [cols] [rows]`
//! 每個 scenario 餵入指定量的 bytes(64 KiB chunks,每 chunk 取一次 damage
//! 模擬 renderer 迴圈),回報吞吐量與快照成本。

use std::time::Instant;

use tterm_term::demo::{self, DemoState};
use tterm_term::TermEngine;

fn run(scenario: u32, data: &[u8], cols: usize, rows: usize) {
    let mut engine = TermEngine::new(cols, rows, 10_000);
    let t0 = Instant::now();
    for chunk in data.chunks(64 * 1024) {
        engine.feed(chunk);
        let _ = engine.drain_events();
        let _ = engine.take_damage();
    }
    let feed = t0.elapsed();

    let t1 = Instant::now();
    let snap = engine.snapshot();
    let snap_t = t1.elapsed();

    let mibs = (data.len() as f64 / (1024.0 * 1024.0)) / feed.as_secs_f64();
    println!(
        "{:<16} {:>10.1} {:>10.0} {:>14.0}",
        demo::scenario_name(scenario),
        mibs,
        feed.as_secs_f64() * 1000.0,
        snap_t.as_secs_f64() * 1e6,
    );
    std::hint::black_box(snap);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mib: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(20);
    let cols: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(120);
    let rows: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(40);
    let target = mib * 1024 * 1024;

    println!("term_bench: {mib} MiB / scenario, grid {cols}x{rows}, scrollback 10000\n");
    println!(
        "{:<16} {:>10} {:>10} {:>14}",
        "scenario", "MiB/s", "ms", "snapshot µs"
    );
    for scenario in [
        demo::SCENARIO_PLAIN,
        demo::SCENARIO_COLORED,
        demo::SCENARIO_CJK,
        demo::SCENARIO_CURSOR_PAINT,
    ] {
        let mut state = DemoState::default();
        let data = demo::gen_chunk(scenario, &mut state, target, cols, rows);
        run(scenario, &data, cols, rows);
    }
}
