//
//  Entry+ZIP64.swift
//  ZIPFoundation
//
//  Copyright © 2017-2026 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

protocol ExtensibleDataField {
    var headerID: UInt16 { get }
    var dataSize: UInt16 { get }
}

extension Entry {

    enum EntryError: Error {
        case missingPermissionsAttributeError
        case missingModificationDateAttributeError
    }

    struct ZIP64ExtendedInformation: ExtensibleDataField {
        let headerID: UInt16 = Archive.ExtraFieldHeaderID.zip64ExtendedInformation.rawValue
        let dataSize: UInt16
        static let headerSize: UInt16 = 4
        let uncompressedSize: UInt64
        let compressedSize: UInt64
        let relativeOffsetOfLocalHeader: UInt64
        let diskNumberStart: UInt32
    }

    var zip64ExtendedInformation: ZIP64ExtendedInformation? {
        self.centralDirectoryStructure.zip64ExtendedInformation
    }
}

typealias Field = Entry.ZIP64ExtendedInformation.Field

extension Entry.LocalFileHeader {
    var validFields: [Field] {
        var fields: [Field] = []
        if self.uncompressedSize == .max { fields.append(.uncompressedSize) }
        if self.compressedSize == .max { fields.append(.compressedSize) }
        return fields
    }
}

extension Entry.CentralDirectoryStructure {
    var validFields: [Field] {
        Self.placeholderFields(uncompressedSize: self.uncompressedSize, compressedSize: self.compressedSize,
                               relativeOffsetOfLocalHeader: self.relativeOffsetOfLocalHeader,
                               diskNumberStart: self.diskNumberStart)
    }

    /// The fields whose header value is the ZIP64 placeholder, in the order their values appear in the
    /// ZIP64 extended information.
    static func placeholderFields(uncompressedSize: UInt32, compressedSize: UInt32,
                                  relativeOffsetOfLocalHeader: UInt32, diskNumberStart: UInt16) -> [Field] {
        var fields: [Field] = []
        if uncompressedSize == .max { fields.append(.uncompressedSize) }
        if compressedSize == .max { fields.append(.compressedSize) }
        if relativeOffsetOfLocalHeader == .max { fields.append(.relativeOffsetOfLocalHeader) }
        if diskNumberStart == .max { fields.append(.diskNumberStart) }
        return fields
    }
    var zip64ExtendedInformation: Entry.ZIP64ExtendedInformation? {
        self.extraFields?.compactMap { $0 as? Entry.ZIP64ExtendedInformation }.first
    }
}

extension Entry.ZIP64ExtendedInformation {

    enum Field {
        case uncompressedSize
        case compressedSize
        case relativeOffsetOfLocalHeader
        case diskNumberStart

        var size: Int {
            switch self {
            case .uncompressedSize, .compressedSize, .relativeOffsetOfLocalHeader:
                return 8
            case .diskNumberStart:
                return 4
            }
        }
    }

    var data: Data {
        var headerID = self.headerID
        var dataSize = self.dataSize
        var uncompressedSize = self.uncompressedSize
        var compressedSize = self.compressedSize
        var relativeOffsetOfLFH = self.relativeOffsetOfLocalHeader
        var diskNumberStart = self.diskNumberStart
        var data = Data()
        withUnsafePointer(to: &headerID, { data.append(UnsafeBufferPointer(start: $0, count: 1))})
        withUnsafePointer(to: &dataSize, { data.append(UnsafeBufferPointer(start: $0, count: 1))})
        if uncompressedSize != 0 || compressedSize != 0 {
            withUnsafePointer(to: &uncompressedSize, { data.append(UnsafeBufferPointer(start: $0, count: 1))})
            withUnsafePointer(to: &compressedSize, { data.append(UnsafeBufferPointer(start: $0, count: 1))})
        }
        if relativeOffsetOfLocalHeader != 0 {
            withUnsafePointer(to: &relativeOffsetOfLFH, { data.append(UnsafeBufferPointer(start: $0, count: 1))})
        }
        if diskNumberStart != 0 {
            withUnsafePointer(to: &diskNumberStart, { data.append(UnsafeBufferPointer(start: $0, count: 1))})
        }
        return data
    }

    /// Serializes the values of `fields` only. Unlike `data`, this writes a value even when it is zero:
    /// a ZIP64 field must hold a value for every header field that contains the placeholder.
    func data(for fields: [Field]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(self.headerID)
        append(UInt16(fields.reduce(0, { $0 + $1.size })))
        if fields.contains(.uncompressedSize) { append(self.uncompressedSize) }
        if fields.contains(.compressedSize) { append(self.compressedSize) }
        if fields.contains(.relativeOffsetOfLocalHeader) { append(self.relativeOffsetOfLocalHeader) }
        if fields.contains(.diskNumberStart) { append(self.diskNumberStart) }
        return data
    }

    /// Returns `extraFieldData` without its ZIP64 extended information, keeping every other extra field.
    /// Trailing bytes that do not form a complete field are kept as they are.
    static func removingZIP64Field(from extraFieldData: Data) -> Data {
        var result = Data()
        var offset = 0
        let headerSize = Int(Self.headerSize)
        while offset + headerSize <= extraFieldData.count {
            let headerID: UInt16 = extraFieldData.scanValue(start: offset)
            let dataSize: UInt16 = extraFieldData.scanValue(start: offset + 2)
            let nextOffset = offset + headerSize + Int(dataSize)
            guard nextOffset <= extraFieldData.count else { break }
            if headerID != Archive.ExtraFieldHeaderID.zip64ExtendedInformation.rawValue {
                result.append(extraFieldData.subdata(in: offset..<nextOffset))
            }
            offset = nextOffset
        }
        result.append(extraFieldData.subdata(in: offset..<extraFieldData.count))
        return result
    }

    init?(data: Data, fields: [Field]) {
        let headerLength = 4
        guard fields.reduce(0, { $0 + $1.size }) + headerLength == data.count else { return nil }

        var readOffset = headerLength
        func value<T>(of field: Field) -> T where T: BinaryInteger {
            if fields.contains(field), readOffset + field.size <= data.count {
                defer { readOffset += MemoryLayout<T>.size }

                return data.scanValue(start: readOffset)
            } else {
                return 0
            }
        }

        self.dataSize = data.scanValue(start: 2)
        self.uncompressedSize = value(of: .uncompressedSize)
        self.compressedSize = value(of: .compressedSize)
        self.relativeOffsetOfLocalHeader = value(of: .relativeOffsetOfLocalHeader)
        self.diskNumberStart = value(of: .diskNumberStart)
    }

    init?(zip64ExtendedInformation: Entry.ZIP64ExtendedInformation?, offset: UInt64,
          maxOffsetOfLocalFileHeader: UInt32) {
        // Only used when removing entry, if no ZIP64 extended information exists,
        // then this information will not be newly added either.
        // A value can be zero and still belong in the rewritten field, so this keeps every value. The
        // rewritten central directory record writes the ones its placeholders need, with `data(for:)`.
        guard let existingInfo = zip64ExtendedInformation else { return nil }
        relativeOffsetOfLocalHeader = offset >= maxOffsetOfLocalFileHeader ? offset : 0
        uncompressedSize = existingInfo.uncompressedSize
        compressedSize = existingInfo.compressedSize
        diskNumberStart = existingInfo.diskNumberStart
        dataSize = existingInfo.dataSize
    }

    static func scanForZIP64Field(in data: Data, fields: [Field]) -> Entry.ZIP64ExtendedInformation? {
        guard data.isEmpty == false else { return nil }
        var offset = 0
        var headerID: UInt16
        var dataSize: UInt16
        let extraFieldLength = data.count
        let headerSize = Int(Entry.ZIP64ExtendedInformation.headerSize)
        while offset < extraFieldLength - headerSize {
            headerID = data.scanValue(start: offset)
            dataSize = data.scanValue(start: offset + 2)
            let nextOffset = offset + headerSize + Int(dataSize)
            guard nextOffset <= extraFieldLength else { return nil }
            if headerID == Archive.ExtraFieldHeaderID.zip64ExtendedInformation.rawValue {
                return Entry.ZIP64ExtendedInformation(data: data.subdata(in: offset..<nextOffset), fields: fields)
            }
            offset = nextOffset
        }
        return nil
    }
}
