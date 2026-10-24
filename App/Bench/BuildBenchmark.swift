import CryptoKit
import FontsMakerKit
import Foundation
import Testing
import os

/// Full builds on a real device (plan, Phase 3b) of the effect cards as they
/// switch on (加粗 at 12, 直排, 簡轉繁 with phrases) and of 加粗＋直排: wall time
/// and peak memory of `RecipeBuilder.build`, the call the app's build makes.
/// Only the FontsMakerBench scheme runs this, built Release (Debug is several
/// times slower) and one combination per process, so each process's lifetime
/// peak belongs to one. Results are printed as `BENCH` lines for the driver
/// script to collect, under the names the 3b presets had.
@Suite(.serialized)
struct BuildBenchmark {
    static let runs = 3

    @Test func ebookBold() throws { try measure("ebook-bold") }
    @Test func pseudoVertical() throws { try measure("pseudo-vertical") }
    @Test func s2t() throws { try measure("s2t") }
    @Test func boldPseudoVertical() throws { try measure("bold-pseudo-vertical") }

    /// The steps and style each combination builds with, as the app's cards
    /// set them (`RecipeDraft.defaultWeight`, `defaultS2T`).
    static let combinations: [String: (style: String, steps: [Recipe.Step])] = [
        "ebook-bold": ("Medium", [.embolden(EmboldenStep(weight: 12))]),
        "pseudo-vertical": ("Regular", [.pseudoVertical(PseudoVerticalOptions(punctuation: .centered))]),
        "s2t": ("Regular", [.s2t(S2TOptions(mode: .single, taiwanVariants: true, phrases: true))]),
        "bold-pseudo-vertical": (
            "Medium",
            [.embolden(EmboldenStep(weight: 12)), .pseudoVertical(PseudoVerticalOptions(punctuation: .centered))]
        ),
    ]

    /// What phrases cost the live preview before its first page
    /// (`EditorModel.converter`): deriving the s2t card's rules from the
    /// source font, which the app does once per options.
    @Test func s2tConverter() throws {
        let data = try sourceData()
        let options = S2TOptions(mode: .single, taiwanVariants: true, phrases: true)
        let font = try Font(data: data)
        print("BENCH preset=s2t-converter cores=\(ProcessInfo.processInfo.activeProcessorCount) before=\(mb(Footprint.read().current))")
        for run in 1...BuildBenchmark.runs {
            let sampler = FootprintSampler()
            let clock = ContinuousClock()
            let start = clock.now
            let converter = try S2TTextConverter(font: font, options: options)
            let elapsed = clock.now - start
            let peak = sampler.stop()
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("BENCH preset=s2t-converter run=\(run) seconds=\(String(format: "%.3f", seconds)) sampledPeakMB=\(mb(peak))")
            #expect(converter.convert("后来里程碑") == "後來里程碑", "the card's options include phrases")
        }
        print("BENCH preset=s2t-converter lifetimePeakMB=\(mb(Footprint.read().lifetimePeak))")
    }

    private func sourceData() throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        // Copied into the bundle at build time from the fixtures cache; fonts are never committed.
        let fontURL = try #require(bundle.url(forResource: "GuanKiapTsingKhai", withExtension: "ttf"))
        return try Data(contentsOf: fontURL)
    }

    private func measure(_ presetID: String) throws {
        let data = try sourceData()
        let combination = try #require(BuildBenchmark.combinations[presetID])
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let recipe = Recipe(
            source: Recipe.Source(file: "GuanKiapTsingKhai.ttf", sha256: sha256),
            output: Recipe.Output(familyName: "Bench Kai", styleName: combination.style),
            steps: combination.steps)
        print("BENCH preset=\(presetID) cores=\(ProcessInfo.processInfo.activeProcessorCount) before=\(mb(Footprint.read().current))")

        for run in 1...BuildBenchmark.runs {
            let sampler = FootprintSampler()
            let clock = ContinuousClock()
            let start = clock.now
            let result = try RecipeBuilder.build(recipe, sourceData: data, options: BuildOptions())
            let elapsed = clock.now - start
            let peak = sampler.stop()
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print(
                "BENCH preset=\(presetID) run=\(run) seconds=\(String(format: "%.3f", seconds)) sampledPeakMB=\(mb(peak)) bytes=\(result.fontData.count)"
            )
            #expect(result.fontData.count > 1_000_000)
        }
        print("BENCH preset=\(presetID) lifetimePeakMB=\(mb(Footprint.read().lifetimePeak))")
    }

    private func mb(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
}

final class BundleToken {}

/// phys_footprint, the figure jetsam enforces an app's memory limit on.
enum Footprint {
    static func read() -> (current: UInt64, lifetimePeak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "task_info failed: \(result)")
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }
}

/// Polls phys_footprint every 5 ms from its own thread for the peak during
/// one build; the kernel's own peak covers the whole process.
final class FootprintSampler: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (running: true, peak: UInt64(0)))
    private let finished = DispatchSemaphore(value: 0)

    init() {
        Thread.detachNewThread { [self] in
            while state.withLock({ $0.running }) {
                let now = Footprint.read().current
                state.withLock { $0.peak = max($0.peak, now) }
                usleep(5_000)
            }
            finished.signal()
        }
    }

    func stop() -> UInt64 {
        state.withLock { $0.running = false }
        finished.wait()
        let last = Footprint.read().current
        return state.withLock { max($0.peak, last) }
    }
}
