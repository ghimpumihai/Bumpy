import Foundation

/// Zips a session folder for export (system directory zipping via NSFileCoordinator; no dependencies).
enum FolderZipper {
    /// Export zips live in their own folder under tmp/, so cleanup can never touch anything else.
    static var defaultExportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    /// Produces `<exportDirectory>/<folder>.zip` using the system's built-in directory zipping.
    /// The caller owns the file and removes it (`removeExport`) when the share sheet is done.
    static func zip(_ folder: URL, into exportDirectory: URL = defaultExportDirectory) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        var coordError: NSError?
        var output: URL?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { zipURL in
            let dest = exportDirectory.appendingPathComponent(folder.lastPathComponent + ".zip")
            do {
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: zipURL, to: dest)
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

    /// Deletes one export zip (a session zip can be GBs of audio; tmp/ is only purged by iOS
    /// under storage pressure).
    static func removeExport(_ zip: URL) {
        do {
            try FileManager.default.removeItem(at: zip)
        } catch CocoaError.fileNoSuchFile {
            // already gone
        } catch {
            appLogger.error("could not delete export \(zip.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Launch cleanup: export zips from a run that was killed with the share sheet open, plus zips
    /// that older app versions left directly in tmp/. Returns the number of files removed.
    @discardableResult
    static func removeStaleExports(exportDirectory: URL = defaultExportDirectory,
                                   legacyDirectory: URL = FileManager.default.temporaryDirectory) -> Int {
        let fm = FileManager.default
        var removed = 0
        for dir in [exportDirectory, legacyDirectory] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "zip" {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        return removed
    }
}

/// What one "Export session" attempt (zip → share sheet) shows and whether it counts as exported.
/// Pure state machine, unit-tested; the view only renders it.
enum ExportState: Equatable {
    case idle
    case zipping
    /// The zip is built and the share sheet is up. `error`: an activity failed but the sheet is
    /// still open (the user can pick another one).
    case sharing(name: String, bytes: Int64, error: String? = nil)
    /// A share activity reported success (AirDrop sent, saved to Files, …).
    case exported(name: String, bytes: Int64)
    case cancelled(name: String, bytes: Int64)
    case failed(String)

    /// Only zipping blocks the Export button: if the share sheet ever failed to appear, its
    /// callback would never come, and Export must not stay disabled forever.
    var isBusy: Bool { self == .zipping }

    /// Callback of the share sheet (`UIActivityViewController.completionWithItemsHandler`).
    /// - Returns: the next state, and whether the sheet is gone so the zip can be deleted. Since
    ///   iOS 13 the sheet stays up when the user backs out of an activity (completed == false,
    ///   activity != nil); the zip must survive that so another activity can still use it.
    func shareFinished(completed: Bool, activity: String?, error: String?) -> (state: ExportState, sheetClosed: Bool) {
        let sheetClosed = completed || activity == nil
        guard case let .sharing(name, bytes, previousError) = self else { return (self, sheetClosed) }
        if completed { return (.exported(name: name, bytes: bytes), true) }
        let lastError = error ?? previousError
        guard sheetClosed else { return (.sharing(name: name, bytes: bytes, error: lastError), false) }
        if let lastError { return (.failed("Export failed: \(lastError)"), true) }
        return (.cancelled(name: name, bytes: bytes), true)
    }
}
