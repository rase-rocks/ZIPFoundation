# Changelog

## [Unreleased]

Merges upstream `weichsel/ZIPFoundation` `main` at `ab380fc`, which includes every change
listed under upstream 0.9.21 below. Where upstream and the fork fixed the same problem,
upstream's fix is kept unless the fork's was stricter.

### Removed
 - Removed Info-ZIP Unicode Path support, following upstream. Entry paths are decoded from
   the central directory file name again. The fork's bounds check for that extra field goes
   with it.

### Fixed
 - Fixed the central directory size recorded after removing an entry when the records of
   other entries changed size. An entry added afterwards used to be lost. (upstream)
 - Replaced the fork's rewrite of ZIP64 extended information on removal with upstream's,
   which also adds ZIP64 extended information to entries moved behind the maximum offset.
 - Rejected entries that declare an uncompressed size beyond `Int64.max` with
   `invalidEntrySize` instead of `entryExceedsMaximumSize`.

### Updated
 - Made `Package@swift-6.4.swift`, added upstream, build in Swift 6 language mode like
   `Package@swift-6.0.swift`. Upstream's version uses Swift 5.
 - Kept the fork's checks where they are stricter than upstream's: the bound on inflated
   output, the removal of files that fail their CRC-32 check, the Windows path separator
   handling (now applied to upstream's symlink-aware containment check) and the seek-range
   check in `Data.readStruct`.
 - Replaced the fork's symlink target limit with upstream's equivalent, which also reads
   stored destinations in chunks.

### Upstream 0.9.21
 - Added support for compressed symlinks
 - Added `symlinksValidWithin` parameter to control symlink containment
 - Added support for symlink modification dates on Linux
 - Added initial support for building for Windows
 - Added package manifest for Swift 6.4
 - Fixed symlink containment bypass via chained symlinks
 - Fixed crashes and endless loops when reading malformed archives
 - Fixed crash when adding entries to archives with an invalid central directory
 - Fixed data loss and invalid offsets when removing entries
 - Fixed sizes of ZIP64 entries with 4 byte data descriptors
 - Fixed reading of ZIP64 archives with a low "version needed to extract"
 - Fixed detection of directory entries with a trailing path delimiter
 - Fixed memory growth and slow opening of archives with many entries
 - Fixed build errors on Android
 - Fixed warnings in package manifest
 - Improved path traversal checks for entries and symlinks during extraction

## [1.0.1]

Brings in upstream commit `e9dec3a` (weichsel/ZIPFoundation#378) ahead of an upstream
release, with a matching fix on the writing side.

### Fixed
 - Fixed reading ZIP64 entries whose ZIP64 extended information holds a size or offset of 0.
   A ZIP64 value now applies when its 32-bit field holds the placeholder `0xFFFFFFFF`, not
   when the value is non-zero. Archives whose first entry carries its offset in the ZIP64
   field used to list no entries. (upstream #378)
 - Accepted ZIP64 end of central directory records whose version needed to extract is below
   4.5, as some producers write them. (upstream #378)
 - Fixed removing an entry from an archive whose other entries carry zero values in their
   ZIP64 extended information. The rewritten central directory record now holds a ZIP64 value
   for every field that contains the placeholder. Such entries used to read back with a size
   of `0xFFFFFFFF`.
 - Kept the other extra fields of an entry with ZIP64 extended information, such as timestamps
   or the Info-ZIP Unicode path, when removing a different entry. They used to be dropped.

## [1.0.0]

First release of the `rase-rocks` fork, based on upstream `weichsel/ZIPFoundation`
`development` at `e7a17d5` (after 0.9.20, which upstream has not yet released).
The major version marks a breaking change relative to 0.9.20: the package now
builds in Swift 6 language mode and raises its platform floors.

### Removed
 - Removed the hand-maintained `ZIPFoundation.xcodeproj` and with it Carthage support.
   The project had drifted out of sync with the package manifests and was never built by CI.
   Swift Package Manager is now the supported integration path.

### Added
 - Added a `maximumSize` parameter to `Archive.extract(...)` that bounds the number of
   uncompressed bytes an entry may produce, guarding against decompression ("zip") bombs.
   Exceeding it throws the new `ArchiveError.entryExceedsMaximumSize(size:limit:)`. Defaults
   to `.max`, preserving existing behavior.
 - Added Swift 6 language-mode support (new `Package@swift-6.0.swift` manifest)

### Security
 - Fixed an out-of-bounds read / crash when parsing malformed Info-ZIP Unicode Path extra fields
 - Fixed out-of-bounds access from unvalidated seek offsets in the in-memory `MemoryFile` backing store
 - Fixed an integer-overflow crash on ZIP64 offsets exceeding the platform seek range in
   `Data.readStruct` (found via fuzzing)
 - Bounds-checked `Data.scanValue` against the buffer length
 - Removed partially-extracted files when a CRC-32 check fails
 - Clamped stored symbolic-link target size to `PATH_MAX`
 - Normalized backslashes before the extraction containment check on Windows

### Updated
 - Released the in-memory stream cookie when stream creation fails (leak on error path)
 - Made `Archive.ArchiveError` conform to `Equatable`

## [0.9.20](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.20)

### Added
 - Added support for file modification date attributes on non-Darwin platforms
 - Added code page 437 string decoding for paths on non-Darwin platforms

### Updated
 - Fixed resource leak in `Archive.makeBackingConfiguration`
 - Fixed memory leak in `Data.readChunk`
 - Fixed memory alignment crash in debug mode
 - Fixed API type reason ID in privacy manifest
 - Improved error handling in `MemoryFile` type
 - Improved `String` to `Data` conversion to use non-optional API
 - Improved error handling for `ftello` operations
 - Improved README examples to use non-deprecated API
 - Improved CI configuration and linting

## [0.9.19](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.19)

### Updated
 - Fixed privacy manifest
 - Fixed deprecation warning in package manifest
 - Fixed resource bundling instruction in the podspec

## [0.9.18](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.18)

### Added
 - Added ability to enforce symlink containment

### Updated
 - Fixed path escape vulnerability
 - Fixed platform requirement warnings
 - Improved error info when encountering permission errors

## [0.9.17](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.17)

### Added
 - Added visionOS support
 - Added Xcode privacy manifest
 - Added throwing initializers for `Archive`
 
### Updated
 - Improved symlink handling
 - Improved forwarding of underlying errors

## [0.9.16](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.16)

### Added
 - Added `isCompressed` accessor to `Entry`
 
### Updated
 - Improved README and documentation
 - Fixed deprecation in the random test data generator

## [0.9.15](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.15)

### Added
 - Added initial support for building for Android
 
### Updated
 - Fixed CRC32 calculation for non-final compression streams
 - Fixed evaluation of CRC32 checksums when using `FileManager.unzipItem`

## [0.9.14](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.14)

### Updated
 - Fixed missing extra field data after entry removal

## [0.9.13](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.13)

### Added
 - Added large file support (ZIP64)
 
### Updated
 - Fixed an `UInt16` overflow when calculating the number of entries
 - Fixed entry removal for in-memory archives
 - Fixed a crash when `fopen()` fails during archive replacement
 - Improved CRC32 calculation performance via zlib (when available)

## [0.9.12](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.12)

### Added
 - Added check to disallow removal of entries from readonly archives
 - Added guard against API misuse by providing zero byte buffer sizes
 
### Updated
 - Fixed an `UInt16` overflow when calculating the end of the central directory record
 - Fixed detection of ZIP version required to extract
 - Fixed missing consumer closure call for zero byte entries
 - Fixed erroneous application of `.deflate` compression on `.symlink` and `.directory` entries
 - Improved detection of `.directory` entries
 - Improved performance when looking up entries via subscripting
 - Improved consistency of URL format used in the Swift package description

## [0.9.11](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.11)

### Added
 - Read/Write support for in-memory archives
 
### Updated
 - Fixed a memory safety issue during (de)compression
 - Fixed dangling pointer warnings when serializing ZIP internal structs to `Data`
 - Fixed missing Swift 5 language version when integrating via CocoaPods
 - Fixed inconsistent usage of the optional `preferredEncoding` parameter during entry addition
 - Improved documentation for compression settings

## [0.9.10](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.10)

### Added
 - Optional `skipCRC32` parameter to speed up entry reading
 
### Updated
 - Fixed a race condition during archive creation or extraction
 - Fixed an error when trying to add broken symlinks to an archive
 - Fixed an App Store submission issue by updating the product identifier to use reverse DNS notation
 - Improved CRC32 calculation performance
 - Improved entry replacement performance on separate volumes
 - Improved documentation for closure-based writing

## [0.9.9](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.9)

### Added
 - Swift 5.0 support
 - Optional `preferredEncoding` parameter to explicitly configure an encoding for filepaths
 
### Updated
 - Fixed a library load error related to dylib versioning
 - Fixed a hang during read when decoding small, `.deflate` compressed entries
 - Improved Linux support
 - Improved test suite on non-Darwin platforms

## [0.9.8](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.8)

### Updated
- Disabled symlink resolution during path traversal checking

## [0.9.7](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.7)

### Added
 - App extension support
 - Optional `compressionMethod` parameter for `zipItem:`
 
### Updated
 - Fixed a path traversal attack vulnerability
 - Fixed a crash due to wrong error handling after failed `fopen` calls

### Removed
 - Temporarily removed the currently unsupported `.modificationDate` attribute on non-Darwin platforms

## [0.9.6](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.6)

### Added
 - Swift 4.1 support
 
### Updated
 - Fixed default directory permissions
 - Fixed a compile issue when targeting Linux

## [0.9.5](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.5)

### Added
 - Progress tracking support
 - Operation cancellation support
 
### Updated
 - Improved performance of CRC32 calculations
 - Improved Linux support
 - Fixed wrong behaviour when using the `shouldKeepParent` flag
 - Fixed a linker error during archive builds when integrating via Carthage

## [0.9.4](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.4)

### Updated
 - Fixed a wrong setting for `FRAMEWORK_SEARCH_PATHS` that interfered with code signing
 - Added a proper value for `CURRENT_PROJECT_VERSION` to make the framework App Store compliant when using Carthage

## [0.9.3](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.3)

### Added
 - Carthage support
 
### Updated
 - Improved error handling
 - Made consistent use of Swift's `CocoaError` instead of `NSError`

## [0.9.2](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.2)

### Updated
 - Changed default POSIX permissions when file attributes are missing
 - Improved docs
 - Fixed a compiler warning when compiling with the latest Xcode 9 beta

## [0.9.1](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.1)

### Added
 - Optional parameter to skip CRC32 checksum calculation
 
### Updated
 - Tweaked POSIX buffer sizes to improve IO and comrpression performance
 - Improved source readability
 - Refined documentation
 
### Removed
 - Optional parameter skip decompression during entry retrieval
 
## [0.9.0](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.0)

### Added
 - Initial release of ZIP Foundation.
