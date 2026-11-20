import Foundation

/// Zips a session folder for export (system directory zipping via NSFileCoordinator; no dependencies).
enum FolderZipper {
    /// Produces `<tmp>/<folder>.zip` using the system's built-in directory zipping.
    static func zip(_ folder: URL) throws -> URL {
        var coordError: NSError?
        var output: URL?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { zipURL in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(folder.lastPathComponent + ".zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipURL, to: dest)
                output = dest
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        guard let output else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
}
