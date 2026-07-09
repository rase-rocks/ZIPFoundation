//
//  ZIPFoundationProgressTests.swift
//  ZIPFoundation
//
//  Copyright © 2017-2026 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//
import XCTest
@testable import ZIPFoundation

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
extension ZIPFoundationTests {

    func testArchiveAddUncompressedEntryProgress() {
        // The archive is only ever touched on `zipQueue` (async work, then the `sync` verification
        // below); the `wait` in between runs on the test thread and does not access it. This queue
        // confinement is safe but not provable to the compiler, hence `nonisolated(unsafe)`.
        nonisolated(unsafe) let archive = self.archive(for: #function, mode: .update)
        let assetURL = self.resourceURL(for: #function, pathExtension: "png")
        let progress = archive.makeProgressForAddingItem(at: assetURL)
        let handler: XCTKVOExpectation.Handler = { (_, _) -> Bool in
            if progress.fractionCompleted > 0.5 {
                progress.cancel()
                return true
            }
            return false
        }
        let cancel = self.keyValueObservingExpectation(for: progress, keyPath: #keyPath(Progress.fractionCompleted),
                                                       handler: handler)
        let zipQueue = DispatchQueue(label: "ZIPFoundationTests")
        zipQueue.async {
            do {
                let relativePath = assetURL.lastPathComponent
                let baseURL = assetURL.deletingLastPathComponent()
                try archive.addEntry(with: relativePath, relativeTo: baseURL, bufferSize: 1, progress: progress)
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            } catch {
                XCTFail("Failed to add entry to uncompressed folder archive with error : \(error)")
            }
        }
        self.wait(for: [cancel], timeout: 20.0)
        zipQueue.sync {
            XCTAssert(progress.fractionCompleted > 0.5)
            XCTAssert(archive.checkIntegrity())
        }
    }

    func testArchiveAddCompressedEntryProgress() {
        // The archive is only ever touched on `zipQueue` (async work, then the `sync` verification
        // below); the `wait` in between runs on the test thread and does not access it. This queue
        // confinement is safe but not provable to the compiler, hence `nonisolated(unsafe)`.
        nonisolated(unsafe) let archive = self.archive(for: #function, mode: .update)
        let assetURL = self.resourceURL(for: #function, pathExtension: "png")
        let progress = archive.makeProgressForAddingItem(at: assetURL)
        let handler: XCTKVOExpectation.Handler = { (_, _) -> Bool in
            if progress.fractionCompleted > 0.5 {
                progress.cancel()
                return true
            }
            return false
        }
        let cancel = self.keyValueObservingExpectation(for: progress, keyPath: #keyPath(Progress.fractionCompleted),
                                                       handler: handler)
        let zipQueue = DispatchQueue(label: "ZIPFoundationTests")
        zipQueue.async {
            do {
                let relativePath = assetURL.lastPathComponent
                let baseURL = assetURL.deletingLastPathComponent()
                try archive.addEntry(with: relativePath, relativeTo: baseURL,
                                     compressionMethod: .deflate, bufferSize: 1, progress: progress)
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            } catch {
                XCTFail("Failed to add entry to uncompressed folder archive with error : \(error)")
            }
        }
        self.wait(for: [cancel], timeout: 20.0)
        zipQueue.sync {
            XCTAssert(progress.fractionCompleted > 0.5)
            XCTAssert(archive.checkIntegrity())
        }
    }

    func testRemoveEntryProgress() {
        // The archive is only ever touched on `zipQueue` (async work, then the `sync` verification
        // below); the `wait` in between runs on the test thread and does not access it. This queue
        // confinement is safe but not provable to the compiler, hence `nonisolated(unsafe)`.
        nonisolated(unsafe) let archive = self.archive(for: #function, mode: .update)
        guard let foundEntry = archive["test/data.random"] else {
            XCTFail("Failed to find entry to remove in uncompressed folder")
            return
        }
        // Confined to `zipQueue` alongside `archive` (see note above).
        nonisolated(unsafe) let entryToRemove = foundEntry
        let progress = archive.makeProgressForRemoving(entryToRemove)
        let handler: XCTKVOExpectation.Handler = { (_, _) -> Bool in
            if progress.fractionCompleted > 0.5 {
                progress.cancel()
                return true
            }
            return false
        }
        let cancel = self.keyValueObservingExpectation(for: progress, keyPath: #keyPath(Progress.fractionCompleted),
                                                       handler: handler)
        let zipQueue = DispatchQueue(label: "ZIPFoundationTests")
        zipQueue.async {
            do {
                try archive.remove(entryToRemove, progress: progress)
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            } catch {
                XCTFail("Failed to remove entry from uncompressed folder archive with error : \(error)")
            }
        }
        self.wait(for: [cancel], timeout: 20.0)
        zipQueue.sync {
            XCTAssert(progress.fractionCompleted > 0.5)
            XCTAssert(archive.checkIntegrity())
        }
    }

    func testZipItemProgress() throws {
        let assetURL = self.resourceURL(for: #function, pathExtension: "png")
        let fileArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
            .appendingPathComponent(self.archiveName(for: #function))
        let fileProgress = Progress()
        let fileExpectation = self.keyValueObservingExpectation(for: fileProgress,
                                                                keyPath: #keyPath(Progress.fractionCompleted),
                                                                expectedValue: 1.0)
        let testQueue = DispatchQueue.global()
        testQueue.async {
            do {
                try FileManager().zipItem(at: assetURL, to: fileArchiveURL, progress: fileProgress)
            } catch { XCTFail("Failed to zip item with error : \(error)") }
        }
        let directoryURL = ZIPFoundationTests.tempZipDirectoryURL
            .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        let directoryArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
            .appendingPathComponent(self.archiveName(for: #function, suffix: "Directory"))
        let newAssetURL = directoryURL.appendingPathComponent(assetURL.lastPathComponent)
        let directoryProgress = Progress()
        let directoryExpectation = self.keyValueObservingExpectation(for: directoryProgress,
                                                                     keyPath: #keyPath(Progress.fractionCompleted),
                                                                     expectedValue: 1.0)
        testQueue.async {
            do {
                let fileManager = FileManager()
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
                try fileManager.createDirectory(at: directoryURL.appendingPathComponent("nested"),
                                                withIntermediateDirectories: true, attributes: nil)
                try fileManager.copyItem(at: assetURL, to: newAssetURL)
                try fileManager.createSymbolicLink(at: directoryURL.appendingPathComponent("link"),
                                                   withDestinationURL: newAssetURL)
                try fileManager.zipItem(at: directoryURL, to: directoryArchiveURL, progress: directoryProgress)
            } catch { XCTFail("Failed to zip directory with error : \(error)") }
        }
        self.wait(for: [fileExpectation, directoryExpectation], timeout: 20.0)
        let archive = try Archive(url: fileArchiveURL, accessMode: .read)
        XCTAssert(archive.checkIntegrity())
        let directoryArchive = try Archive(url: directoryArchiveURL, accessMode: .read)
        XCTAssert(directoryArchive.checkIntegrity())
    }

    func testUnzipItemProgress() {
        // The archive is only used within the background closure below, never on the test thread.
        nonisolated(unsafe) let archive = self.archive(for: #function, mode: .read)
        let destinationURL = self.createDirectory(for: #function)
        let progress = Progress()
        let expectation = self.keyValueObservingExpectation(for: progress,
                                                            keyPath: #keyPath(Progress.fractionCompleted),
                                                            expectedValue: 1.0)
        DispatchQueue.global().async {
            let fileManager = FileManager()
            do {
                try fileManager.unzipItem(at: archive.url, to: destinationURL, progress: progress)
            } catch {
                XCTFail("Failed to extract item."); return
            }
            var itemsExist = false
            for entry in archive {
                let directoryURL = destinationURL.appendingPathComponent(entry.path)
                itemsExist = fileManager.itemExists(at: directoryURL)
                if !itemsExist { break }
            }
            XCTAssert(itemsExist)
        }
        self.wait(for: [expectation], timeout: 10.0)
    }

    func testZIP64ArchiveAddEntryProgress() {
        // See the note in `testArchiveAddUncompressedEntryProgress`: the archive is confined to `zipQueue`.
        nonisolated(unsafe) let archive = self.archive(for: #function, mode: .update,
                                                       zip64Thresholds: self.mockThresholds())
        let assetURL = self.resourceURL(for: #function, pathExtension: "png")
        let progress = archive.makeProgressForAddingItem(at: assetURL)
        let handler: XCTKVOExpectation.Handler = { (_, _) -> Bool in
            if progress.fractionCompleted > 0.5 {
                progress.cancel()
                return true
            }
            return false
        }
        let cancel = self.keyValueObservingExpectation(for: progress, keyPath: #keyPath(Progress.fractionCompleted),
                                                       handler: handler)
        let zipQueue = DispatchQueue(label: "ZIPFoundationTests")
        zipQueue.async {
            do {
                let relativePath = assetURL.lastPathComponent
                let baseURL = assetURL.deletingLastPathComponent()
                try archive.addEntry(with: relativePath, relativeTo: baseURL,
                                     compressionMethod: .deflate, bufferSize: 1, progress: progress)
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            } catch {
                XCTFail("Failed to add entry to uncompressed folder archive with error : \(error)")
            }
        }
        self.wait(for: [cancel], timeout: 20.0)
        zipQueue.sync {
            XCTAssert(progress.fractionCompleted > 0.5)
            XCTAssert(archive.checkIntegrity())
        }
    }
}
#endif
