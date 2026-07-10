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
}
#endif
