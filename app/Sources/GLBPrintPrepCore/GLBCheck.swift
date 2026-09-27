import Foundation

/// Minimal verification, independent of the engine, run before the app touches any original:
/// the file exists, is a GLB v2, the header length matches the file size and it declares no
/// compression extension.
public enum GLBCheck {
    public static let compressionExtensions = [
        "EXT_meshopt_compression", "KHR_mesh_quantization", "KHR_draco_mesh_compression",
    ]

    /// Returns nil if the file passes, otherwise a short description of the problem.
    public static func problem(with url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "output file is not readable" }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 20), head.count == 20 else { return "output file is too short" }
        let u32 = { (offset: Int) in head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard u32(0) == 0x4654_6C67 else { return "missing glTF magic" }
        guard u32(4) == 2 else { return "unexpected GLB version" }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard Int(u32(8)) == size else { return "declared length ≠ file size" }
        let jsonLength = Int(u32(12))
        guard let json = try? handle.read(upToCount: jsonLength), let text = String(data: json, encoding: .utf8) else {
            return "unreadable JSON chunk"
        }
        for ext in compressionExtensions where text.contains(ext) {
            return "still contains \(ext)"
        }
        return nil
    }
}
