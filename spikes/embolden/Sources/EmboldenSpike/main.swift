import CoreGraphics
import Foundation

struct Args {
    var opts: [String: String] = [:]

    init(_ argv: ArraySlice<String>) {
        var it = argv.makeIterator()
        while let a = it.next() {
            guard a.hasPrefix("--") else { fail("unexpected argument \(a)") }
            opts[String(a.dropFirst(2))] = it.next() ?? ""
        }
    }

    func str(_ k: String, _ d: String? = nil) -> String {
        guard let v = opts[k] ?? d else { fail("missing --\(k)") }
        return v
    }

    func int(_ k: String, _ d: Int) -> Int {
        guard let s = opts[k] else { return d }
        guard let v = Int(s) else { fail("--\(k) expects an integer") }
        return v
    }

    func cg(_ k: String, _ d: CGFloat) -> CGFloat {
        guard let s = opts[k] else { return d }
        guard let v = Double(s) else { fail("--\(k) expects a number") }
        return CGFloat(v)
    }
}

let usage = """
usage: embolden-spike <command> [--key value ...]
  analyze  --font F [--ref R] --out CSV [--weight 12] [--join miter|round] [--miter-limit 4] [--chars S | --limit N]
  timing   --font F [--mode single|background|parallel] [--join ..] [--stride N] [--threads N] [--out CSV]
  sheet    --font F [--ref R --ref-by gid|char --ref-label L] (--chars S | --list TSV) --out PREFIX [--title T]
  overlay  --font F --ref R (--chars S | --list TSV) --out PREFIX [--join ..] [--compare-join J] [--window x,y,size] [--title T]
  dump     --font F --gids 1,2,3 [--join ..] [--quantize 1]
  final    --final OUT.ttf --src F --ref R --out CSV [--weight 12] [--miter-limit 4]
  final-sheet   --final OUT.ttf --src F --ref R --chars S --out PREFIX [--ref-label L] [--title T]
  crossing-zoom --final OUT.ttf --list TSV(gid,x,y,label) --out PREFIX [--window 24] [--title T]
"""

let argv = CommandLine.arguments
guard argv.count >= 2 else { print(usage); exit(1) }
let args = Args(argv.dropFirst(2))
switch argv[1] {
case "analyze": runAnalyze(args)
case "timing": runTiming(args)
case "sheet": runSheet(args)
case "overlay": runOverlay(args)
case "dump": runDump(args)
case "final": runFinal(args)
case "final-sheet": runFinalSheet(args)
case "crossing-zoom": runCrossingZoom(args)
default: print(usage); exit(1)
}
