import Darwin
import Foundation

/// The file observed by the probe. nanosecond timestamps avoid rounding away an
/// in-place edit; device/inode also detect replacement with otherwise equal metadata.
public struct TranscodeSourceRevision: Equatable, Sendable {
    private let device: dev_t
    private let inode: ino_t
    private let size: off_t
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    public init(fileDescriptor: Int32) throws {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WallpaperError("转码输入必须是普通文件。") }
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}
