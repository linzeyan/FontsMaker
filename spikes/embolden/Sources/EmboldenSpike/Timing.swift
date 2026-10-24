import CoreGraphics
import Foundation

private func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func pct(_ sorted: [Double], _ p: Double) -> Double {
    sorted[min(sorted.count - 1, Int(p / 100 * Double(sorted.count)))]
}

/// Runs `work` on a dedicated thread with the given QoS. On Apple silicon,
/// .background confines the thread to efficiency cores, which is how we
/// approximate an iPhone's E-core throughput without a device.
private func onThread(_ qos: QualityOfService, _ work: @escaping () -> Void) {
    let done = DispatchSemaphore(value: 0)
    let t = Thread { work(); done.signal() }
    t.qualityOfService = qos
    t.stackSize = 8 << 20
    t.start()
    done.wait()
}

/// Engine-only timing (path extraction, stroke, union) — no metrics, so the
/// numbers reflect what the real build pipeline would pay.
func runTiming(_ a: Args) {
    let src = LoadedFont(path: a.str("font"))
    let params = EmboldenParams(weight: a.cg("weight", 12), join: parseJoin(a.str("join", "miter")),
                                miterLimit: a.cg("miter-limit", 4))
    let all = selectGlyphs(a, src)
    let stride = a.int("stride", 1)
    let gids = Swift.stride(from: 0, to: all.count, by: stride).map { all[$0] }
    let mode = a.str("mode", "single")
    print("timing mode \(mode) join \(params.label) glyphs \(gids.count) (stride \(stride) of \(all.count)) cores \(ProcessInfo.processInfo.activeProcessorCount)")

    // Warm-up: first CoreText/CG calls fault in tables and caches.
    for g in gids.prefix(300) { if let p = src.outline(g) { _ = embolden(p, params) } }

    switch mode {
    case "single", "background":
        var ext = [Double](repeating: 0, count: gids.count)
        var str = ext, uni = ext
        var sink = 0.0
        let qos: QualityOfService = mode == "single" ? .userInteractive : .background
        let wall0 = nowNs()
        onThread(qos) {
            for (i, g) in gids.enumerated() {
                autoreleasepool {
                    let t0 = nowNs()
                    guard let p = src.outline(g) else { return }
                    let t1 = nowNs()
                    let s = p.copy(strokingWithWidth: params.weight, lineCap: .butt, lineJoin: params.join,
                                   miterLimit: params.miterLimit)
                    let t2 = nowNs()
                    let b = p.union(s, using: .winding)
                    let t3 = nowNs()
                    sink += Double(b.boundingBoxOfPath.width)
                    ext[i] = Double(t1 - t0) / 1000
                    str[i] = Double(t2 - t1) / 1000
                    uni[i] = Double(t3 - t2) / 1000
                }
            }
        }
        let wall = Double(nowNs() - wall0) / 1e9
        let engine = zip(str, uni).map { $0 + $1 }
        let sorted = engine.sorted()
        let total = engine.reduce(0, +) / 1e6
        print(String(format: "wall %.2f s; engine (stroke+union) sum %.2f s; extract sum %.2f s; stroke sum %.2f s; union sum %.2f s",
                     wall, total, ext.reduce(0, +) / 1e6, str.reduce(0, +) / 1e6, uni.reduce(0, +) / 1e6))
        print(String(format: "per-glyph engine us: mean %.1f median %.1f p95 %.1f p99 %.1f max %.1f",
                     total * 1e6 / Double(gids.count), pct(sorted, 50), pct(sorted, 95), pct(sorted, 99), sorted.last!))
        print(String(format: "extrapolated full font (%d glyphs) single-thread: %.1f s",
                     all.count, total * Double(all.count) / Double(gids.count)))
        let slow = engine.indices.sorted { engine[$0] > engine[$1] }.prefix(10)
        print("slowest: " + slow.map { "\(gids[$0])/\(src.name(gids[$0])):\(Int(engine[$0]))us" }.joined(separator: " "))
        print("sink \(sink)")
        if let out = a.opts["out"] {
            var text = "gid,t_extract_us,t_stroke_us,t_union_us\n"
            for i in gids.indices {
                text += String(format: "%d,%.1f,%.1f,%.1f\n", Int(gids[i]), ext[i], str[i], uni[i])
            }
            do { try text.write(toFile: out, atomically: true, encoding: .utf8) } catch { fail("write \(out): \(error)") }
            print("wrote \(out)")
        }
    case "parallel":
        let threads = a.int("threads", 0)
        for run in 1...a.int("repeat", 3) {
            let t0 = nowNs()
            if threads > 0 {
                // Fixed worker count to see how throughput scales with cores.
                let q = OperationQueue()
                q.maxConcurrentOperationCount = threads
                q.qualityOfService = .userInitiated
                let chunk = 64
                for c in Swift.stride(from: 0, to: gids.count, by: chunk) {
                    q.addOperation {
                        for g in gids[c..<min(gids.count, c + chunk)] {
                            autoreleasepool { if let p = src.outline(g) { _ = embolden(p, params) } }
                        }
                    }
                }
                q.waitUntilAllOperationsAreFinished()
            } else {
                DispatchQueue.concurrentPerform(iterations: gids.count) { i in
                    autoreleasepool { if let p = src.outline(gids[i]) { _ = embolden(p, params) } }
                }
            }
            let wall = Double(nowNs() - t0) / 1e9
            print(String(format: "run %d: %d glyphs in %.2f s wall (%@ threads) = %.0f glyphs/s",
                         run, gids.count, wall, threads > 0 ? "\(threads)" : "all", Double(gids.count) / wall))
        }
    default:
        fail("unknown mode \(mode)")
    }
}
