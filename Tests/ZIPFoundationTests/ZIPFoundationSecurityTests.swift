//
//  ZIPFoundationSecurityTests.swift
//  ZIPFoundation
//
//  Copyright © 2017-2026 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import XCTest
@testable import ZIPFoundation

extension ZIPFoundationTests {

    /// Regression test for the Info-ZIP Unicode Path extra-field parser (H1).
    ///
    /// A record that declares a `dataSize` too small to hold its fixed part (version + nameCRC32,
    /// i.e. fewer than 9 bytes total) must be rejected instead of triggering an out-of-bounds read
    /// (`scanValue(start: 5)`) and an invalid `subdata(in: 9..<count)` range. A well-formed record
    /// must still parse.
    func testInfoZIPUnicodePathShortRecordIsRejected() {
        // headerID 0x7075 (little-endian), dataSize = 1, one payload byte → 5-byte field total.
        let malformed = Data([0x75, 0x70, 0x01, 0x00, 0xAA])
        XCTAssertNil(Entry.InfoZIPUnicodePath.scanForUnicodePath(in: malformed),
                     "Undersized Info-ZIP Unicode Path record must be rejected, not read out of bounds")

        // A boundary-sized record (dataSize == 5: version + 4-byte CRC, empty name) is valid.
        let minimalValid = Data([0x75, 0x70, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        let parsedMinimal = Entry.InfoZIPUnicodePath.scanForUnicodePath(in: minimalValid)
        XCTAssertNotNil(parsedMinimal)
        XCTAssertEqual(parsedMinimal?.unicodeName.count, 0)

        // A record with a one-byte name must parse and expose that name.
        let valid = Data([0x75, 0x70, 0x06, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x41])
        let parsed = Entry.InfoZIPUnicodePath.scanForUnicodePath(in: valid)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.dataSize, 6)
        XCTAssertEqual(parsed?.unicodeName, Data([0x41]))
    }

    /// Regression test for the bounds check in `Data.scanValue(start:)`.
    ///
    /// `loadUnaligned` performs no bounds checking of its own, so an offset taken from a malformed,
    /// attacker-controlled archive would read adjacent memory. Every out-of-range offset must
    /// instead yield a zero-filled value. Each case below is rejected by a *different* part of
    /// `start >= 0, start <= self.count - size`, so neither clause can be dropped: `Int.min`
    /// satisfies the second clause and is caught only by the first, `Int.max` is the converse, and
    /// the `count < size` cases make the `self.count - size` right-hand side negative, which must
    /// reject every offset rather than wrap around.
    func testScanValueRejectsOutOfBoundsStart() {
        let data = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])

        // A negative offset must never be dereferenced. `Int.min` passes `start <= count - size`,
        // so only the `start >= 0` clause stands between it and a wild read.
        XCTAssertEqual(data.scanValue(start: -1) as UInt16, 0, "a negative offset must read nothing")
        XCTAssertEqual(data.scanValue(start: Int.min) as UInt32, 0, "Int.min must not reach loadUnaligned")

        // An offset at or far past the end of the buffer.
        XCTAssertEqual(data.scanValue(start: data.count) as UInt16, 0, "offset == count reads past the end")
        XCTAssertEqual(data.scanValue(start: Int.max) as UInt32, 0, "Int.max must not reach loadUnaligned")

        // The off-by-one boundary: `start` itself is in bounds, but `start + MemoryLayout<T>.size`
        // overruns the buffer by exactly one byte. This is the case a naive `start < count` misses.
        XCTAssertEqual(data.scanValue(start: 5) as UInt16, 0, "a 2-byte load at count-1 overruns by one byte")
        XCTAssertEqual(data.scanValue(start: 3) as UInt32, 0, "a 4-byte load at count-3 overruns by one byte")

        // `count < size` makes `self.count - size` negative, so no offset at all is legal.
        XCTAssertEqual(Data([0xAA]).scanValue(start: 0) as UInt32, 0, "1 byte cannot satisfy a 4-byte load")
        XCTAssertEqual(data.scanValue(start: 0) as UInt64, 0, "6 bytes cannot satisfy an 8-byte load")

        // An empty buffer has nothing to read at any offset, including zero.
        XCTAssertEqual(Data().scanValue(start: 0) as UInt16, 0, "an empty buffer must read no UInt16")
        XCTAssertEqual(Data().scanValue(start: 0) as UInt8, 0, "an empty buffer must read no UInt8")
    }

    /// Companion to `testScanValueRejectsOutOfBoundsStart`: the bounds check must not be too tight.
    ///
    /// A guard rejecting one offset too many would silently replace the last field of a
    /// fixed-layout structure with a zero, corrupting archives it was meant to protect. Every byte
    /// here is non-zero, so a zero-filled fallback cannot masquerade as a real read, and
    /// `start == count - MemoryLayout<T>.size` — the largest legal offset, immediately below the
    /// rejected offsets above — must still return the true trailing bytes. Values are
    /// little-endian, matching the ZIP field layout `scanValue` exists to parse.
    func testScanValueReadsLargestValidStart() {
        let data = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])

        // The largest legal offset for each width: start == count - size.
        XCTAssertEqual(data.scanValue(start: 4) as UInt16, 0x6655, "the last 2 bytes must be read, not zeroed")
        XCTAssertEqual(data.scanValue(start: 2) as UInt32, 0x6655_4433, "the last 4 bytes must be read, not zeroed")

        // One byte below the largest legal offset still reads real data.
        XCTAssertEqual(data.scanValue(start: 3) as UInt16, 0x5544)
        XCTAssertEqual(data.scanValue(start: 1) as UInt32, 0x5544_3322)

        // Offset zero for each width, and a buffer sized exactly to one value.
        XCTAssertEqual(data.scanValue(start: 0) as UInt16, 0x2211)
        XCTAssertEqual(data.scanValue(start: 0) as UInt32, 0x4433_2211)
        XCTAssertEqual(Data([0x77, 0x88]).scanValue(start: 0) as UInt16, 0x8877, "count == size must be legal")

        // A single byte is a legal 1-byte load at offset 0, but not at offset 1.
        XCTAssertEqual(Data([0x99]).scanValue(start: 0) as UInt8, 0x99, "count == size == 1 must be legal")
        XCTAssertEqual(Data([0x99]).scanValue(start: 1) as UInt8, 0, "offset 1 of a 1-byte buffer is out of range")
    }
}

#if swift(>=5.0) && (os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(Linux))
extension ZIPFoundationTests {

    /// Regression test for the in-memory backing store's seek handling (H2/M1).
    ///
    /// A crafted archive offset can drive the memory `FILE*` cursor past the end of (or before the
    /// start of) the backing data. Reading past the end must yield EOF (0 bytes) rather than a
    /// negative-size / out-of-bounds copy, and a negative absolute seek must be reported as an error
    /// rather than moving the cursor into an invalid position.
    func testMemoryFileRejectsOutOfBoundsSeek() throws {
        let memoryFile = Archive.MemoryFile(data: Data([0x00, 0x01, 0x02, 0x03]))
        let file = try memoryFile.open(mode: .read)
        defer { fclose(file) }

        // Seeking far past the end is permitted (POSIX); the subsequent read must return EOF.
        XCTAssertEqual(fseeko(file, 1_000_000, SEEK_SET), 0)
        var buffer = [UInt8](repeating: 0xFF, count: 8)
        let bytesRead = buffer.withUnsafeMutableBytes { fread($0.baseAddress, 1, 8, file) }
        XCTAssertEqual(bytesRead, 0, "Reading past the end of an in-memory archive must yield no bytes")

        // A negative absolute position must be rejected without crashing.
        XCTAssertEqual(fseeko(file, -100, SEEK_SET), -1, "A negative absolute seek must be rejected")
    }

    /// Regression test for the absolute decompression cap (`maximumSize`).
    ///
    /// A `maximumSize` smaller than the entry's uncompressed size must cause extraction to throw
    /// `entryExceedsMaximumSize` (up front, on the declared size, before inflating), while the
    /// default `.max` cap extracts the full payload unchanged.
    func testExtractRejectsEntryExceedingMaximumSize() throws {
        let archive = try Archive(data: Data(), accessMode: .create)
        let payload = Data(repeating: 0x41, count: 8192)
        try archive.addEntry(with: "big.txt", type: .file, uncompressedSize: Int64(payload.count),
                             compressionMethod: .deflate, provider: { position, size in
            let start = Int(position)
            return payload.subdata(in: start..<start + size)
        })
        let entry = try XCTUnwrap(archive["big.txt"])

        var produced = Data()
        XCTAssertThrowsError(try archive.extract(entry, maximumSize: 1024,
                                                 consumer: { produced.append($0) })) { error in
            guard case Archive.ArchiveError.entryExceedsMaximumSize = error else {
                return XCTFail("expected entryExceedsMaximumSize, got \(error)")
            }
        }
        XCTAssertTrue(produced.isEmpty, "no bytes should be produced when the declared size exceeds the cap")

        var full = Data()
        _ = try archive.extract(entry, consumer: { full.append($0) })
        XCTAssertEqual(full, payload, "default .max cap must extract the full payload")
    }

    /// Regression test for the ZIP64 offset integer-overflow trap found by fuzzing.
    ///
    /// `readStruct` seeks with `zip_off_t` (a signed type narrower than `UInt64`). A crafted ZIP64
    /// offset above `zip_off_t.max` must be rejected (returns `nil`) rather than trapping in the
    /// `zip_off_t(offset)` conversion ("Not enough bits to represent the passed value").
    func testReadStructRejectsOffsetBeyondSeekRange() throws {
        let memoryFile = Archive.MemoryFile(data: Data([0x00, 0x01, 0x02, 0x03]))
        let file = try memoryFile.open(mode: .read)
        defer { fclose(file) }
        let record: Archive.EndOfCentralDirectoryRecord? =
            Data.readStruct(from: file, at: UInt64(Int64.max) + 1)
        XCTAssertNil(record, "An offset beyond zip_off_t.max must be rejected, not trap")
    }

    /// Regression test for cookie ownership when the backing `FILE*` stream cannot be created.
    ///
    /// `open(mode:)` retains `self` so the stream's cookie keeps the backing store alive, and
    /// `closeStub` balances that retain when the stream is closed. If the stream is never created
    /// `closeStub` never runs, so the failure path must release the cookie itself; otherwise the
    /// `MemoryFile` and its whole `Data` payload leak for the lifetime of the process. The real
    /// `funopen`/`fopencookie` cannot be driven to fail by any `AccessMode`, so the stream factory
    /// is substituted here to model that failure.
    func testMemoryFileOpenFailureReleasesCookie() throws {
        weak var weakFile: Archive.MemoryFile?
        do {
            let memoryFile = Archive.MemoryFile(data: Data([0x00, 0x01, 0x02, 0x03]))
            weakFile = memoryFile
            XCTAssertThrowsError(try memoryFile.open(mode: .read, makeStream: { _, _ in nil })) { error in
                guard case MemoryFileError.invalidMemoryFile = error else {
                    return XCTFail("expected invalidMemoryFile, got \(error)")
                }
            }
            XCTAssertNotNil(weakFile, "the store is still alive inside this scope")
        }
        XCTAssertNil(weakFile, "a failed open must release the cookie instead of leaking the store")
    }

    /// Regression test for the `whence` handling in the in-memory backing store's `seek`.
    ///
    /// The `FILE*` stubs receive `whence` verbatim from whoever drives the stream. Only
    /// `SEEK_SET`/`SEEK_CUR`/`SEEK_END` are meaningful, so any other value is a corrupt request: it
    /// must be reported as an error (-1) and must leave the cursor where it was. Treating an unknown
    /// `whence` as "seek to `offset`" would silently reposition the stream instead of failing.
    func testMemoryFileSeekWhenceHandling() throws {
        let memoryFile = Archive.MemoryFile(data: Data([0x00, 0x01, 0x02, 0x03]))
        XCTAssertEqual(memoryFile.seek(offset: 3, whence: SEEK_SET), 3, "SEEK_SET is absolute")
        XCTAssertEqual(memoryFile.seek(offset: -1, whence: SEEK_CUR), 2, "SEEK_CUR is cursor-relative")
        XCTAssertEqual(memoryFile.seek(offset: -4, whence: SEEK_END), 0, "SEEK_END is end-relative")
        XCTAssertEqual(memoryFile.seek(offset: 2, whence: SEEK_SET), 2)

        // A non-zero `offset` is used for the rejected calls so that an implementation treating an
        // unknown `whence` as SEEK_SET would return that offset rather than coincidentally -1.
        for whence: Int32 in [99, -1, 3, .min, .max] {
            XCTAssertEqual(memoryFile.seek(offset: 1, whence: whence), -1,
                           "An unknown whence (\(whence)) must be rejected")
            XCTAssertEqual(memoryFile.seek(offset: 0, whence: SEEK_CUR), 2,
                           "A rejected seek must leave the cursor untouched")
        }
    }

    /// Regression test for negative absolute positions in the in-memory backing store's `seek`.
    ///
    /// A crafted archive offset can ask the store to seek before the start of its data, via any of
    /// the three valid `whence` values. Each must return -1 *without* moving the cursor: a negative
    /// cursor left behind would let the following `readData`/`writeData` build an out-of-bounds
    /// range. Seeking at or past the end stays legal (POSIX) and must read back as EOF.
    func testMemoryFileSeekRejectsNegativePositions() throws {
        let memoryFile = Archive.MemoryFile(data: Data([0x00, 0x01, 0x02, 0x03]))
        XCTAssertEqual(memoryFile.seek(offset: 2, whence: SEEK_SET), 2)

        // Each target is chosen so the computed position is never itself -1, and the cursor is
        // re-checked after every rejection. An implementation that dropped the guard would both
        // return the out-of-range position and leave the cursor on it.
        for (offset, whence, label) in [(-100, SEEK_SET, "absolute"),
                                        (-50, SEEK_CUR, "cursor-relative"),
                                        (-64, SEEK_END, "end-relative")] {
            XCTAssertEqual(memoryFile.seek(offset: offset, whence: whence), -1,
                           "a negative \(label) target must be rejected")
            XCTAssertEqual(memoryFile.seek(offset: 0, whence: SEEK_CUR), 2,
                           "a rejected \(label) seek must leave the cursor untouched")
        }

        // Past the end is a valid position; the read there must report EOF, not a negative size.
        XCTAssertEqual(memoryFile.seek(offset: 64, whence: SEEK_SET), 64)
        var buffer = [UInt8](repeating: 0xFF, count: 4)
        let bytesRead = buffer.withUnsafeMutableBytes { memoryFile.readData(buffer: $0) }
        XCTAssertEqual(bytesRead, 0, "reading past the end must yield no bytes")
        XCTAssertEqual(buffer, [0xFF, 0xFF, 0xFF, 0xFF], "no bytes may be copied into the buffer")
    }
}

#endif

// MARK: - Linux test registry

// Deliberately outside the platform gate above: `allTests` references `securityTests`
// unconditionally, so it has to exist on every platform.
extension ZIPFoundationTests {

    /// Registered from here rather than from `ZIPFoundationTests.swift`, which already sits at
    /// SwiftLint's 400-line `file_length` ceiling.
    static var securityTests: [(String, (ZIPFoundationTests) -> () throws -> Void)] {
        var tests: [(String, (ZIPFoundationTests) -> () throws -> Void)] = [
            ("testScanValueRejectsOutOfBoundsStart", testScanValueRejectsOutOfBoundsStart),
            ("testScanValueReadsLargestValidStart", testScanValueReadsLargestValidStart)
        ]
        #if swift(>=5.0) && (os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(Linux))
        tests += [
            ("testExtractStopsMidStreamWhenDataDescriptorUnderstatesPayload",
             testExtractStopsMidStreamWhenDataDescriptorUnderstatesPayload),
            ("testExtractClampsNegativeMaximumSizeToZero", testExtractClampsNegativeMaximumSizeToZero),
            ("testExtractRejectsInflatedOutputOverDeclaredSize", testExtractRejectsInflatedOutputOverDeclaredSize),
            ("testMemoryFileOpenFailureReleasesCookie", testMemoryFileOpenFailureReleasesCookie),
            ("testMemoryFileSeekWhenceHandling", testMemoryFileSeekWhenceHandling),
            ("testMemoryFileSeekRejectsNegativePositions", testMemoryFileSeekRejectsNegativePositions)
        ]
        #endif
        return tests
    }
}
