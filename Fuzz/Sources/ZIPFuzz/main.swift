//
//  ZIPFuzz — a structure-aware mutational fuzzer for ZIPFoundation's parse/extract surface.
//
//  It repeatedly mutates a seed corpus of real archives and feeds each result through the
//  untrusted-input path: `Archive(data:)` → iterate entries → read metadata → extract/inflate.
//  Runs deterministically from a seed so any crash reproduces exactly. Build under
//  AddressSanitizer so both Swift traps and out-of-bounds reads abort; a signal handler writes
//  the exact crashing input to a file for triage.
//

import Foundation
import ZIPFoundation

// MARK: - Crash capture (async-signal-safe dump of the current input)

// Touched from the async C signal handler, so they must be reachable from a nonisolated context.
// `nonisolated(unsafe)` is the correct tool here: access is serialized by the single fuzzing
// thread and the handler only ever runs after that thread has faulted.
let gInputCap = 8 << 20 // 8 MiB scratch; inputs are far smaller
nonisolated(unsafe) var gCrashFD: Int32 = -1
nonisolated(unsafe) let gInputBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: gInputCap)
nonisolated(unsafe) var gInputLen = 0

private func crashHandler(_ sig: Int32) {
    if gCrashFD >= 0 && gInputLen > 0 {
        _ = write(gCrashFD, gInputBuf, gInputLen)
        _ = fsync(gCrashFD)
    }
    // Restore the default handler and re-raise so the true signal/exit status propagates.
    signal(sig, SIG_DFL)
    raise(sig)
}

private func installCrashHandlers() {
    for sig in [SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGABRT, SIGFPE] {
        signal(sig, crashHandler)
    }
}

// MARK: - Deterministic RNG

struct XorShift64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private func pick(_ rng: inout XorShift64, _ upper: Int) -> Int {
    upper <= 0 ? 0 : Int(rng.next() % UInt64(upper))
}

// MARK: - Corpus

private func loadCorpus(_ dir: String) -> [[UInt8]] {
    let fm = FileManager()
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    var seeds: [[UInt8]] = []
    for name in names where name.hasSuffix(".zip") {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        if let data = try? Data(contentsOf: url) { seeds.append([UInt8](data)) }
    }
    return seeds
}

// MARK: - Mutation

private let interestingBytes: [UInt8] = [0x00, 0xFF, 0x7F, 0x80, 0x01, 0x50, 0x4B, 0x05, 0x06, 0x01, 0x02, 0x03, 0x04]

private func mutate(_ seed: [UInt8], _ rng: inout XorShift64) -> [UInt8] {
    var bytes = seed
    if bytes.isEmpty { bytes = [0] }
    let rounds = pick(&rng, 24) + 1
    for _ in 0..<rounds {
        switch rng.next() % 7 {
        case 0: // single bit flip
            let i = pick(&rng, bytes.count)
            bytes[i] ^= UInt8(1 << (rng.next() % 8))
        case 1: // random byte
            bytes[pick(&rng, bytes.count)] = UInt8(rng.next() & 0xFF)
        case 2: // interesting byte
            bytes[pick(&rng, bytes.count)] = interestingBytes[pick(&rng, interestingBytes.count)]
        case 3: // truncate
            let n = pick(&rng, bytes.count)
            bytes = Array(bytes.prefix(max(1, n)))
        case 4: // append random tail
            for _ in 0..<pick(&rng, 64) { bytes.append(UInt8(rng.next() & 0xFF)) }
        case 5: // overwrite a 32-bit little-endian field (sizes/offsets/lengths) with a wild value
            if bytes.count >= 4 {
                let i = pick(&rng, bytes.count - 3)
                let v = rng.next()
                bytes[i] = UInt8(v & 0xFF); bytes[i + 1] = UInt8((v >> 8) & 0xFF)
                bytes[i + 2] = UInt8((v >> 16) & 0xFF); bytes[i + 3] = UInt8((v >> 24) & 0xFF)
            }
        default: // overwrite a 16-bit little-endian field (name/extra/comment lengths)
            if bytes.count >= 2 {
                let i = pick(&rng, bytes.count - 1)
                let v = rng.next()
                bytes[i] = UInt8(v & 0xFF); bytes[i + 1] = UInt8((v >> 8) & 0xFF)
            }
        }
    }
    return bytes
}

// MARK: - Harness

private enum FuzzLimit: Error { case outputTooLarge }

// Bound the decompressed output we let a single input produce. A crafted archive can legitimately
// declare a multi-GB uncompressed size (M2 only caps output to the *declared* size), which would
// stall the fuzzer for minutes per input. This is a known DoS vector, not a crash, so we cap it
// here to keep throughput high while still exercising the inflate path.
private let perInputOutputCap = 4 << 20 // 4 MiB — enough to exercise inflate, cheap per input

private func harness(_ bytes: [UInt8]) {
    let data = Data(bytes)
    let archive: Archive
    do { archive = try Archive(data: data, accessMode: .read) } catch { return }
    var seen = 0
    var produced = 0
    for entry in archive {
        _ = entry.path
        _ = entry.checksum
        _ = entry.type
        _ = try? archive.extract(entry, bufferSize: 4096, skipCRC32: false, consumer: { chunk in
            produced += chunk.count
            if produced > perInputOutputCap { throw FuzzLimit.outputTooLarge }
        })
        seen += 1
        if seen > 5_000 || produced > perInputOutputCap { break } // don't let one input run away
    }
}

// MARK: - Driver

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let args = CommandLine.arguments
let corpusDir = args.count > 1 ? args[1] : "."
let iterations = args.count > 2 ? (Int(args[2]) ?? 100_000) : 100_000
let seed = args.count > 3 ? (UInt64(args[3]) ?? 1) : 1
let crashOut = args.count > 4 ? args[4] : "/tmp/zipfuzz_crash.bin"

let corpus = loadCorpus(corpusDir)
guard !corpus.isEmpty else { log("ZIPFuzz: no .zip seeds found in \(corpusDir)"); exit(2) }

gCrashFD = open(crashOut, O_CREAT | O_TRUNC | O_RDWR, 0o644)
installCrashHandlers()

log("ZIPFuzz: \(corpus.count) seeds, \(iterations) iterations, seed \(seed), crashOut \(crashOut)")

var rng = XorShift64(seed: seed)
for i in 0..<iterations {
    let input = mutate(corpus[pick(&rng, corpus.count)], &rng)
    // Stage the current input in the async-signal-safe buffer for the crash handler.
    let n = min(input.count, gInputCap)
    input.withUnsafeBytes { gInputBuf.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: n) }
    gInputLen = n
    harness(input)
    if i % 1_000 == 0 { log("ZIPFuzz: iter \(i)") }
}

log("ZIPFuzz: completed \(iterations) iterations with no crash (seed \(seed))")
