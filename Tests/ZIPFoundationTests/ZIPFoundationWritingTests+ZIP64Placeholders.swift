//
//  ZIPFoundationWritingTests+ZIP64Placeholders.swift
//  ZIPFoundation
//
//  Copyright © 2017-2026 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import XCTest
@testable import ZIPFoundation

// Removing an entry rewrites the central directory record of every other entry. These tests check
// that the rewritten record stays readable when an entry's ZIP64 extended information holds a zero:
// some writers put every size and offset in the ZIP64 field, whatever the value, and mark each
// 32-bit field with the placeholder 0xFFFFFFFF.

#if swift(>=5.0) && (os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(Linux))
extension ZIPFoundationTests {

    func testRemoveEntryKeepsStoredEmptyZIP64EntryReadable() throws {
        let bytes = Self.makeArchiveWithZIP64Placeholders([
            .init(name: "empty", method: .none, compressed: Data(), uncompressedSize: 0, crc32: 0),
            .init(name: "b", method: .none, compressed: Data("b".utf8), uncompressedSize: 1,
                  crc32: Data("b".utf8).crc32(checksum: 0))
        ])
        let archive = try Archive(data: bytes, accessMode: .update)
        XCTAssertEqual(try XCTUnwrap(archive["empty"]).uncompressedSize, 0)
        try archive.remove(XCTUnwrap(archive["b"]))
        let entry = try XCTUnwrap(archive["empty"])
        // The rewritten header writes the offset directly and keeps the placeholder in both size fields,
        // so the rewritten ZIP64 field must hold both sizes although each is zero. A field that does not
        // match its placeholders fails to parse and the sizes resolve to 0xFFFFFFFF.
        XCTAssertEqual(entry.uncompressedSize, 0)
        XCTAssertEqual(entry.compressedSize, 0)
        // With a size of 0xFFFFFFFF, extraction would return the central directory as the entry's content.
        var extracted = Data()
        XCTAssertEqual(try archive.extract(entry, consumer: { extracted.append($0) }), 0)
        XCTAssertEqual(extracted, Data())
    }

    func testRemoveEntryKeepsDeflatedEmptyZIP64EntryReadable() throws {
        // An empty deflate stream is two bytes long, so only the uncompressed size is zero.
        let bytes = Self.makeArchiveWithZIP64Placeholders([
            .init(name: "empty", method: .deflate, compressed: Data([0x03, 0x00]), uncompressedSize: 0, crc32: 0),
            .init(name: "b", method: .none, compressed: Data("b".utf8), uncompressedSize: 1,
                  crc32: Data("b".utf8).crc32(checksum: 0))
        ])
        let archive = try Archive(data: bytes, accessMode: .update)
        XCTAssertEqual(try XCTUnwrap(archive["empty"]).uncompressedSize, 0)
        try archive.remove(XCTUnwrap(archive["b"]))
        let entry = try XCTUnwrap(archive["empty"])
        // Only the compressed size is non-zero, but the rewritten ZIP64 field must still hold both sizes.
        XCTAssertEqual(entry.uncompressedSize, 0)
        XCTAssertEqual(entry.compressedSize, 2)
        var extracted = Data()
        XCTAssertEqual(try archive.extract(entry, consumer: { extracted.append($0) }), 0)
        XCTAssertEqual(extracted, Data())
    }

    func testRemoveEntryKeepsOtherExtraFieldsOfZIP64Entry() throws {
        // An extended timestamp field (0x5455) with a modification time.
        let timestamp = Data([0x55, 0x54, 0x05, 0x00, 0x01, 0x00, 0x5e, 0x37, 0x69])
        let bytes = Self.makeArchiveWithZIP64Placeholders([
            .init(name: "a", method: .none, compressed: Data("a".utf8), uncompressedSize: 1,
                  crc32: Data("a".utf8).crc32(checksum: 0), otherExtraField: timestamp),
            .init(name: "b", method: .none, compressed: Data("b".utf8), uncompressedSize: 1,
                  crc32: Data("b".utf8).crc32(checksum: 0))
        ])
        let archive = try Archive(data: bytes, accessMode: .update)
        try archive.remove(XCTUnwrap(archive["b"]))
        let entry = try XCTUnwrap(archive["a"])
        let extraFieldData = entry.centralDirectoryStructure.extraFieldData
        XCTAssertEqual([UInt8](extraFieldData.prefix(timestamp.count)), [UInt8](timestamp))
        XCTAssertEqual(entry.uncompressedSize, 1)
        var extracted = Data()
        _ = try archive.extract(entry, consumer: { extracted.append($0) })
        XCTAssertEqual(extracted, Data("a".utf8))
    }
}

// MARK: - Helper

extension ZIPFoundationTests {

    struct PlaceholderEntry {
        let name: String
        let method: CompressionMethod
        let compressed: Data
        let uncompressedSize: UInt64
        let crc32: CRC32
        var otherExtraField = Data()
    }

    /// Builds an archive in which every entry carries its sizes and offset in its ZIP64 extended
    /// information and 0xFFFFFFFF in the matching 32-bit fields, whatever the values. Any other extra
    /// field of an entry goes before its ZIP64 field in the central directory.
    static func makeArchiveWithZIP64Placeholders(_ entries: [PlaceholderEntry]) -> Data {
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        var archive = Data()
        var centralDirectory = Data()
        for entry in entries {
            let offset = UInt64(archive.count)
            let name = Data(entry.name.utf8)
            let compressedSize = UInt64(entry.compressed.count)
            // Local file header: signature, version 4.5, flags, method, time, date, CRC, sizes, lengths.
            append(UInt32(localFileHeaderStructSignature), to: &archive)
            [UInt16(45), 0, entry.method.rawValue, 0, 0x21].forEach { append($0, to: &archive) }
            [entry.crc32, .max, .max].forEach { append($0, to: &archive) }
            [UInt16(name.count), 20].forEach { append($0, to: &archive) }
            archive.append(name)
            [UInt16(1), 16].forEach { append($0, to: &archive) }
            [entry.uncompressedSize, compressedSize].forEach { append($0, to: &archive) }
            archive.append(entry.compressed)
            // Central directory record: as above plus comment length, disk, attributes and offset.
            append(UInt32(centralDirectoryStructSignature), to: &centralDirectory)
            [UInt16(0x032d), 45, 0, entry.method.rawValue, 0, 0x21].forEach { append($0, to: &centralDirectory) }
            [entry.crc32, .max, .max].forEach { append($0, to: &centralDirectory) }
            let extraFieldLength = UInt16(28 + entry.otherExtraField.count)
            [UInt16(name.count), extraFieldLength, 0, 0, 0].forEach { append($0, to: &centralDirectory) }
            [UInt32(0o100644 << 16), .max].forEach { append($0, to: &centralDirectory) }
            centralDirectory.append(name)
            centralDirectory.append(entry.otherExtraField)
            [UInt16(1), 24].forEach { append($0, to: &centralDirectory) }
            [entry.uncompressedSize, compressedSize, offset].forEach { append($0, to: &centralDirectory) }
        }
        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        append(UInt32(endOfCentralDirectoryStructSignature), to: &archive)
        [UInt16(0), 0, UInt16(entries.count), UInt16(entries.count)].forEach { append($0, to: &archive) }
        [UInt32(centralDirectory.count), centralDirectoryOffset].forEach { append($0, to: &archive) }
        append(UInt16(0), to: &archive)
        return archive
    }
}
#endif
