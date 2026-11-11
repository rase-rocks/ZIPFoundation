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

// Extraction-cap security tests, and the crafted-archive builders they need. Split out of
// ZIPFoundationSecurityTests.swift to stay under SwiftLint's 400-line `file_length` limit.

#if swift(>=5.0) && (os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(Linux))
extension ZIPFoundationTests {

    /// Regression test for the running-total half of the absolute decompression cap (`maximumSize`).
    ///
    /// `extract` applies the cap twice, and the two checks read *different* sizes. The up-front check
    /// uses `Entry.uncompressedSize`, which prefers the data descriptor's size, while the read helpers
    /// stream `centralDirectoryStructure.effectiveUncompressedSize`. A crafted archive whose data
    /// descriptor understates the real payload therefore slips past the up-front check, and only the
    /// running total over the bytes actually produced can stop it. Without that second check the size
    /// an attacker declares would be the only gate, which is the whole point of the cap.
    func testExtractStopsMidStreamWhenDataDescriptorUnderstatesPayload() throws {
        let payloadByteCount = 4096
        let understatedSize = UInt32(16)
        let bytes = try Self.makeArchiveUnderstatingPayloadSize(payloadByteCount: payloadByteCount,
                                                                understatedSize: understatedSize)
        let archive = try Archive(data: bytes, accessMode: .read)
        let entry = try XCTUnwrap(archive["understated.txt"])

        // The forgery: the data descriptor claims 16 bytes, the central directory still says 4096.
        XCTAssertEqual(entry.uncompressedSize, UInt64(understatedSize),
                       "the up-front check must see the understated data descriptor size")
        XCTAssertEqual(entry.centralDirectoryStructure.effectiveUncompressedSize, UInt64(payloadByteCount),
                       "the read path must still stream the full payload")

        let cap = 1024
        let chunkSize = 256
        var produced = Data()
        XCTAssertThrowsError(try archive.extract(entry, bufferSize: chunkSize, maximumSize: cap,
                                                 consumer: { produced.append($0) })) { error in
            guard case Archive.ArchiveError.entryExceedsMaximumSize(let size, let limit) = error else {
                return XCTFail("expected entryExceedsMaximumSize, got \(error)")
            }
            XCTAssertEqual(limit, UInt64(cap))
            XCTAssertGreaterThan(size, limit, "the cap must trip on bytes produced, not on the declared size")
            XCTAssertLessThanOrEqual(size, limit + UInt64(chunkSize),
                                     "extraction must stop within one chunk of the cap, not run to completion")
        }
        // The guard trips on the first chunk that pushes the running total past the cap, so the
        // consumer sees every whole chunk that fits. Derived from `cap`/`chunkSize` rather than
        // assuming the two divide evenly.
        XCTAssertLessThanOrEqual(produced.count, cap,
                                 "the consumer must never receive more than maximumSize bytes")
        XCTAssertEqual(produced.count, cap - (cap % chunkSize),
                       "every whole chunk below the cap must be delivered, and nothing past it")
    }

    /// Regression test for the `maximumSize` clamp on negative input.
    ///
    /// `maximumSize` is an `Int`, so a caller can pass a negative value. Converting that straight to
    /// `UInt64` would wrap into an enormous limit and silently disable the cap, so negatives clamp to
    /// `0`: nothing that produces bytes may be extracted. A directory entry produces no bytes at all,
    /// so it must still extract cleanly under a zero cap.
    func testExtractClampsNegativeMaximumSizeToZero() throws {
        let archive = try Archive(data: Data(), accessMode: .create)
        let payload = Data("ZIPFoundation".utf8)
        try archive.addEntry(with: "file.txt", type: .file, uncompressedSize: Int64(payload.count),
                             compressionMethod: .none, provider: { _, _ in payload })
        try archive.addEntry(with: "directory", type: .directory, uncompressedSize: Int64(0),
                             provider: { _, _ in Data() })
        let fileEntry = try XCTUnwrap(archive["file.txt"])
        let directoryEntry = try XCTUnwrap(archive["directory"])

        var produced = Data()
        XCTAssertThrowsError(try archive.extract(fileEntry, maximumSize: -1,
                                                 consumer: { produced.append($0) })) { error in
            guard case Archive.ArchiveError.entryExceedsMaximumSize(let size, let limit) = error else {
                return XCTFail("expected entryExceedsMaximumSize, got \(error)")
            }
            XCTAssertEqual(limit, 0, "a negative maximumSize must clamp to 0, not wrap to UInt64.max")
            XCTAssertEqual(size, UInt64(payload.count))
        }
        XCTAssertTrue(produced.isEmpty, "no bytes may be produced under a zero cap")

        var directoryChunks = 0
        _ = try archive.extract(directoryEntry, maximumSize: -1, consumer: { _ in directoryChunks += 1 })
        XCTAssertEqual(directoryChunks, 1, "a zero-byte directory entry is unaffected by a zero cap")
    }

    /// Regression test for the inflate-overrun guard in `readCompressed` (the classic "zip bomb").
    ///
    /// A deflate stream can inflate to far more data than the entry's central directory declares.
    /// Without the running `totalDecompressed <= maxUncompressedSize` cap, those surplus bytes would be
    /// streamed on to the consumer (and to disk) unbounded, driven only by the attacker's stream rather
    /// than by any size the archive admits to. An archive whose central directory understates the real
    /// inflated size must therefore fail with `invalidEntrySize`, and — the property that actually
    /// matters — the consumer must never be handed more than the declared number of bytes.
    func testExtractRejectsInflatedOutputOverDeclaredSize() throws {
        let payloadSize = 64 * 1024
        let declaredSize = UInt32(4096)
        let raw = try Self.makeUndersizedDeflateArchive(payloadSize: payloadSize,
                                                        declaredUncompressedSize: declaredSize)
        let archive = try Archive(data: raw, accessMode: .read)
        let entry = try XCTUnwrap(archive["bomb.txt"], "the patched archive must still parse")
        XCTAssertEqual(entry.uncompressedSize, UInt64(declaredSize),
                       "the central directory must understate the real inflated size")

        var produced = Data()
        XCTAssertThrowsError(try archive.extract(entry, bufferSize: 1024,
                                                 consumer: { produced.append($0) })) { error in
            guard case Archive.ArchiveError.invalidEntrySize = error else {
                return XCTFail("expected invalidEntrySize, got \(error)")
            }
        }
        // The guard throws before `try consumer(data)`, so this bound holds for any inflate chunk
        // size: only whole chunks that kept the running total within the declared size get through.
        XCTAssertLessThanOrEqual(produced.count, Int(declaredSize),
                                 "the consumer must not receive more than the declared byte count")
        XCTAssertLessThan(produced.count, payloadSize,
                          "the full zip-bomb payload must never reach the consumer")
    }
}

// MARK: - Crafted archive builders

extension ZIPFoundationTests {

    /// Builds a single-entry, stored archive and then forges a data descriptor for it: the central
    /// directory gets general-purpose bit 3 set (so the iterator parses a descriptor) while keeping the
    /// true `uncompressedSize`, and the inserted descriptor reports `understatedSize` instead.
    static func makeArchiveUnderstatingPayloadSize(payloadByteCount: Int,
                                                   understatedSize: UInt32) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        let payload = Data(repeating: 0x41, count: payloadByteCount)
        try archive.addEntry(with: "understated.txt", type: .file,
                             uncompressedSize: Int64(payloadByteCount),
                             compressionMethod: .none, provider: { position, size in
            let start = Int(position)
            return payload.subdata(in: start..<start + size)
        })
        var bytes = Data(try XCTUnwrap(archive.data))
        let eocdOffset = bytes.count - Archive.EndOfCentralDirectoryRecord.size
        XCTAssertEqual(Self.readUInt32(bytes, at: eocdOffset), UInt32(endOfCentralDirectoryStructSignature),
                       "offset arithmetic below assumes the archive ends with an EOCD and no comment")
        let cdOffset = Int(Self.readUInt32(bytes, at: eocdOffset + 16))
        let headerOffset = Int(Self.readUInt32(bytes, at: cdOffset + 42))
        let nameLength = Int(Self.readUInt16(bytes, at: headerOffset + 26))
        let extraLength = Int(Self.readUInt16(bytes, at: headerOffset + 28))
        let dataOffset = headerOffset + Entry.LocalFileHeader.size + nameLength + extraLength

        var descriptor = Self.littleEndianBytes(UInt32(dataDescriptorStructSignature))
        descriptor.append(Self.littleEndianBytes(payload.crc32(checksum: 0)))
        descriptor.append(Self.littleEndianBytes(understatedSize))
        descriptor.append(Self.littleEndianBytes(understatedSize))
        XCTAssertEqual(descriptor.count, Entry.DefaultDataDescriptor.size)
        bytes.insert(contentsOf: descriptor, at: dataOffset + payloadByteCount)

        // Flag the descriptor in both headers, then move the central directory past the inserted bytes.
        let shiftedCDOffset = cdOffset + descriptor.count
        bytes[headerOffset + 6] |= 0x08
        bytes[shiftedCDOffset + 8] |= 0x08
        Self.writeUInt32(&bytes, UInt32(shiftedCDOffset),
                         at: bytes.count - Archive.EndOfCentralDirectoryRecord.size + 16)
        return bytes
    }

    /// Builds an in-memory archive holding one deflated, highly compressible entry, then rewrites the
    /// central directory's `uncompressedSize` field — offset 24 of the 46-byte record, fixed by
    /// APPNOTE 4.3.12 — so the entry declares fewer bytes than its stored deflate stream really
    /// inflates to. Only that one field is overwritten in place, so no structure offsets shift and
    /// the archive still parses. The stored compressed size is never relied upon, so the test is
    /// independent of the toolchain's deflate output.
    static func makeUndersizedDeflateArchive(payloadSize: Int,
                                             declaredUncompressedSize: UInt32) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        let payload = Data(repeating: 0x41, count: payloadSize)
        try archive.addEntry(with: "bomb.txt", type: .file, uncompressedSize: Int64(payloadSize),
                             compressionMethod: .deflate, provider: { position, size in
            let start = Int(position)
            return payload.subdata(in: start..<start + size)
        })
        var raw = try XCTUnwrap(archive.data)
        let uncompressedSizeOffset = Int(archive.offsetToStartOfCentralDirectory) + 24
        // Pin the field offset: if the record layout ever moves, fail here with a clear reason
        // rather than silently corrupting a neighbouring field and testing nothing.
        let storedSize: UInt32 = raw.scanValue(start: uncompressedSizeOffset)
        XCTAssertEqual(storedSize, UInt32(payloadSize),
                       "offset 24 of the 46-byte central directory record must hold uncompressedSize")
        let patch = withUnsafeBytes(of: declaredUncompressedSize.littleEndian) { Data($0) }
        raw.replaceSubrange(uncompressedSizeOffset..<(uncompressedSizeOffset + 4), with: patch)
        return raw
    }

    static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }

    static func littleEndianBytes(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    static func writeUInt32(_ data: inout Data, _ value: UInt32, at offset: Int) {
        data.replaceSubrange(offset..<offset + 4, with: Self.littleEndianBytes(value))
    }
}
#endif
