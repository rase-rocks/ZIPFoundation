//
//  Archive+MemoryFile.swift
//  ZIPFoundation
//
//  Copyright © 2017-2026 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

extension Archive {
    var isMemoryArchive: Bool { return self.url.scheme == memoryURLScheme }
}

// In-memory archives rely on a `FILE*`-shaped userspace stream API:
// `funopen` on Apple, `fopencookie` on Linux glibc. File-backed archives
// continue to work on platforms without a compatible userspace stream API.
#if swift(>=5.0) && (os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(Linux))

extension Archive {

    class MemoryFile {

        private(set) var data: Data
        private var offset = 0

        init(data: Data = Data()) {
            self.data = data
        }

        func open(mode: AccessMode) throws -> FILEPointer {
            let cookie = Unmanaged.passRetained(self)
            #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
            guard let result = mode.isWritable
                ? funopen(cookie.toOpaque(), readStub, writeStub, seekStub, closeStub)
                : funopen(cookie.toOpaque(), readStub, nil, seekStub, closeStub)
            else {
                // `closeStub` (which balances this retain) is never called if the stream isn't
                // created, so release the cookie here to avoid leaking `self`.
                cookie.release()
                throw MemoryFileError.invalidMemoryFile
            }
            #else
            let stubs = cookie_io_functions_t(read: readStub, write: writeStub, seek: seekStub, close: closeStub)
            guard let result = fopencookie(cookie.toOpaque(), mode.posixMode, stubs)
            else {
                cookie.release()
                throw MemoryFileError.invalidMemoryFile
            }
            #endif
            return result
        }
    }

    /// Returns a `Data` object containing a representation of the receiver.
    public var data: Data? { return self.memoryFile?.data }
}

public enum MemoryFileError: Error {
    case invalidMemoryFile
}

private extension Archive.MemoryFile {

    func readData(buffer: UnsafeMutableRawBufferPointer) -> Int {
        // The cursor can legitimately sit at or past the end of the data (e.g. after a seek beyond
        // EOF driven by a crafted archive offset). Reading there must yield zero bytes rather than
        // letting `data.count - offset` go negative and produce an out-of-bounds copy range.
        guard offset >= 0, offset <= data.count else { return 0 }
        let size = min(buffer.count, data.count-offset)
        let start = data.startIndex
        self.data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: start+offset..<start+offset+size)
        self.offset += size
        return size
    }

    func writeData(buffer: UnsafeRawBufferPointer) -> Int {
        // A negative cursor would produce out-of-bounds subrange arithmetic below. `seek` already
        // rejects negative positions; this guard keeps the invariant local to the write path.
        guard offset >= 0 else { return 0 }
        let start = self.data.startIndex
        if self.offset < self.data.count && self.offset+buffer.count > self.data.count {
            self.data.removeSubrange(start+self.offset..<start+self.data.count)
        } else if offset > data.count {
            self.data.append(Data(count: self.offset-self.data.count))
        }
        if self.offset == self.data.count {
            self.data.append(buffer.bindMemory(to: UInt8.self))
        } else {
            let start = self.data.startIndex // May have changed in earlier mutation
            self.data.replaceSubrange(
                start+self.offset..<start+self.offset+buffer.count,
                with: buffer.bindMemory(to: UInt8.self)
            )
        }
        self.offset += buffer.count
        return buffer.count
    }

    func seek(offset: Int, whence: Int32) -> Int {
        let result: Int
        if whence == SEEK_SET {
            result = offset
        } else if whence == SEEK_CUR {
            result = self.offset + offset
        } else if whence == SEEK_END {
            result = data.count + offset
        } else {
            return -1
        }
        // A negative absolute position is invalid. Report an error (-1) without moving the cursor
        // so that a crafted archive offset cannot drive `readData`/`writeData` out of bounds.
        // Positions at or beyond the end remain valid (POSIX allows seeking past EOF); the read
        // and write paths handle those cases safely.
        guard result >= 0 else { return -1 }
        self.offset = result
        return self.offset
    }
}

private func fileFromCookie(cookie: UnsafeRawPointer) -> Archive.MemoryFile {
    return Unmanaged<Archive.MemoryFile>.fromOpaque(cookie).takeUnretainedValue()
}

private func closeStub(_ cookie: UnsafeMutableRawPointer?) -> Int32 {
    if let cookie = cookie {
        Unmanaged<Archive.MemoryFile>.fromOpaque(cookie).release()
    }
    return 0
}

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)

private func readStub(_ cookie: UnsafeMutableRawPointer?,
                      _ bytePtr: UnsafeMutablePointer<Int8>?,
                      _ count: Int32) -> Int32 {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    return Int32(fileFromCookie(cookie: cookie).readData(
                    buffer: UnsafeMutableRawBufferPointer(start: bytePtr, count: Int(count))))
}

private func writeStub(_ cookie: UnsafeMutableRawPointer?,
                       _ bytePtr: UnsafePointer<Int8>?,
                       _ count: Int32) -> Int32 {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    return Int32(fileFromCookie(cookie: cookie).writeData(
                    buffer: UnsafeRawBufferPointer(start: bytePtr, count: Int(count))))
}

private func seekStub(_ cookie: UnsafeMutableRawPointer?,
                      _ offset: fpos_t,
                      _ whence: Int32) -> fpos_t {
    guard let cookie = cookie else { return 0 }
    return fpos_t(fileFromCookie(cookie: cookie).seek(offset: Int(offset), whence: whence))
}

#else

extension Archive.AccessMode {

    var posixMode: String {
        switch self {
        case .read: return "rb"
        case .create: return "wb+"
        case .update: return "rb+"
        }
    }
}

private func readStub(_ cookie: UnsafeMutableRawPointer?,
                      _ bytePtr: UnsafeMutablePointer<Int8>?,
                      _ count: Int) -> Int {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    return fileFromCookie(cookie: cookie).readData(
        buffer: UnsafeMutableRawBufferPointer(start: bytePtr, count: count))
}

private func writeStub(_ cookie: UnsafeMutableRawPointer?,
                       _ bytePtr: UnsafePointer<Int8>?,
                       _ count: Int) -> Int {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    return fileFromCookie(cookie: cookie).writeData(
        buffer: UnsafeRawBufferPointer(start: bytePtr, count: count))
}

private func seekStub(_ cookie: UnsafeMutableRawPointer?,
                      _ offset: UnsafeMutablePointer<Int>?,
                      _ whence: Int32) -> Int32 {
    guard let cookie = cookie, let offset = offset else { return 0 }
    let result = fileFromCookie(cookie: cookie).seek(offset: Int(offset.pointee), whence: whence)
    if result >= 0 {
        offset.pointee = result
        return 0
    } else {
        return -1
    }
}
#endif
#endif
