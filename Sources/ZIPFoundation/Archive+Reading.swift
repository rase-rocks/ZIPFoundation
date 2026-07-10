//
//  Archive+Reading.swift
//  ZIPFoundation
//
//  Copyright © 2017-2026 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation
#if canImport(Android)
import Android
#endif

extension Archive {
    /// Read a ZIP `Entry` from the receiver and write it to `url`.
    ///
    /// - Parameters:
    ///   - entry: The ZIP `Entry` to read.
    ///   - url: The destination file URL.
    ///   - bufferSize: The maximum size of the read buffer and the decompression buffer (if needed).
    ///   - skipCRC32: Optional flag to skip calculation of the CRC32 checksum to improve performance.
    ///   - symlinksValidWithin: Any symlink target that resolves outside this URL is rejected for security reasons.
    ///                          Pass `.rootFS` to allow symlinks to point anywhere on the filesystem.
    ///   - progress: A progress object that can be used to track or cancel the extract operation.
    /// - Returns: The checksum of the processed content or 0 if the `skipCRC32` flag was set to `true`.
    /// - Throws: An error if the destination file cannot be written or the entry contains malformed content.
    public func extract(_ entry: Entry, to url: URL, bufferSize: Int = defaultReadChunkSize,
                        skipCRC32: Bool = false,
                        symlinksValidWithin: URL? = nil,
                        maximumSize: Int = .max,
                        progress: Progress? = nil) throws -> CRC32 {
        guard bufferSize > 0 else {
            throw ArchiveError.invalidBufferSize
        }
        let fileManager = FileManager()
        var checksum = CRC32(0)
        switch entry.type {
        case .file:
            guard fileManager.itemExists(at: url) == false else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            try fileManager.createParentDirectoryStructure(for: url)
            let destinationRepresentation = fileManager.fileSystemRepresentation(withPath: url.path)
            guard let destinationFile: FILEPointer = fopen(destinationRepresentation, "wb+") else {
                throw POSIXError(errno, path: url.path)
            }
            defer { fclose(destinationFile) }
            let consumer = { _ = try Data.write(chunk: $0, to: destinationFile) }
            checksum = try self.extract(entry, bufferSize: bufferSize, skipCRC32: skipCRC32,
                                        progress: progress, maximumSize: maximumSize, consumer: consumer)
        case .directory:
            let consumer = { (_: Data) in
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            }
            checksum = try self.extract(entry, bufferSize: bufferSize, skipCRC32: skipCRC32,
                                        progress: progress, maximumSize: maximumSize, consumer: consumer)
        case .symlink:
            guard fileManager.itemExists(at: url) == false else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            let consumer = { (data: Data) in
                guard let linkPath = String(data: data, encoding: .utf8) else { throw ArchiveError.invalidEntryPath }

                let parentURL = url.deletingLastPathComponent()
                let isAbsolutePath = (linkPath as NSString).isAbsolutePath
                let linkURL = URL(fileURLWithPath: linkPath, relativeTo: isAbsolutePath ? nil : parentURL)
                let isContained = linkURL.isContained(in: symlinksValidWithin ?? parentURL)
                guard isContained else { throw ArchiveError.uncontainedSymlink }

                try fileManager.createParentDirectoryStructure(for: url)
                try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: linkPath)
            }
            checksum = try self.extract(entry, bufferSize: bufferSize, skipCRC32: skipCRC32,
                                        progress: progress, maximumSize: maximumSize, consumer: consumer)
        }
        try fileManager.transferAttributes(from: entry, toItemAtURL: url)
        return checksum
    }

    /// Read a ZIP `Entry` from the receiver and forward its contents to a `Consumer` closure.
    ///
    /// - Parameters:
    ///   - entry: The ZIP `Entry` to read.
    ///   - bufferSize: The maximum size of the read buffer and the decompression buffer (if needed).
    ///   - skipCRC32: Optional flag to skip calculation of the CRC32 checksum to improve performance.
    ///   - progress: A progress object that can be used to track or cancel the extract operation.
    ///   - consumer: A closure that consumes contents of `Entry` as `Data` chunks.
    /// - Returns: The checksum of the processed content or 0 if the `skipCRC32` flag was set to `true`..
    /// - Throws: An error if the destination file cannot be written or the entry contains malformed content.
    public func extract(_ entry: Entry, bufferSize: Int = defaultReadChunkSize, skipCRC32: Bool = false,
                        progress: Progress? = nil, maximumSize: Int = .max, consumer: Consumer) throws -> CRC32 {
        guard bufferSize > 0 else {
            throw ArchiveError.invalidBufferSize
        }
        // Absolute decompression cap: bound the number of uncompressed bytes this call will produce,
        // independent of the size the archive declares. This prevents a small "zip bomb" entry from
        // inflating to an unbounded amount of data. `maximumSize` defaults to `.max`, preserving the
        // previous unbounded behavior. Reject early on the declared size, then enforce the running
        // total in case the declared size understates the actual output.
        let limit = maximumSize < 0 ? 0 : UInt64(maximumSize)
        if entry.uncompressedSize > limit {
            throw ArchiveError.entryExceedsMaximumSize(size: entry.uncompressedSize, limit: limit)
        }
        guard entry.dataOffset <= .max else { throw ArchiveError.invalidLocalHeaderDataOffset }
        // `withoutActuallyEscaping` lets the byte-counting wrapper close over the non-escaping
        // `consumer` for the duration of extraction without changing the public signature.
        return try withoutActuallyEscaping(consumer) { escapingConsumer -> CRC32 in
            var producedByteCount = UInt64(0)
            let boundedConsumer: Consumer = { data in
                producedByteCount += UInt64(data.count)
                if producedByteCount > limit {
                    throw ArchiveError.entryExceedsMaximumSize(size: producedByteCount, limit: limit)
                }
                try escapingConsumer(data)
            }
            var checksum = CRC32(0)
            let localFileHeader = entry.localFileHeader
            fseeko(self.archiveFile, zip_off_t(entry.dataOffset), SEEK_SET)
            progress?.totalUnitCount = self.totalUnitCountForReading(entry)
            switch entry.type {
            case .file:
                guard let compressionMethod = CompressionMethod(rawValue: localFileHeader.compressionMethod) else {
                    throw ArchiveError.invalidCompressionMethod
                }
                switch compressionMethod {
                case .none: checksum = try self.readUncompressed(entry: entry, bufferSize: bufferSize,
                                                                 skipCRC32: skipCRC32, progress: progress,
                                                                 with: boundedConsumer)
                case .deflate: checksum = try self.readCompressed(entry: entry, bufferSize: bufferSize,
                                                                  skipCRC32: skipCRC32, progress: progress,
                                                                  with: boundedConsumer)
                }
            case .directory:
                try boundedConsumer(Data())
                progress?.completedUnitCount = self.totalUnitCountForReading(entry)
            case .symlink:
                checksum = try self.readSymbolicLink(entry: entry, bufferSize: bufferSize,
                                                     skipCRC32: skipCRC32, progress: progress, with: boundedConsumer)
            }
            return checksum
        }
    }
}
