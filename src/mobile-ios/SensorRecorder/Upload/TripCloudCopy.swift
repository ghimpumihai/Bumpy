import Foundation

/// How much of one trip is known to be in the cloud (D56): every batch the trip queued, the 2 s
/// windows that never entered the queue, and the Stop copy each count as one part. Only parts the
/// backend acknowledged count as sent, so "complete" means the cloud has the whole trip.
struct TripCloudCopy: Equatable {
    let batchesQueued: Int
    let windowsNotQueued: Int
    let state: UploadQueue.TripState

    init(stats: SessionMetadata.Stats?, state: UploadQueue.TripState) {
        batchesQueued = stats?.uploadBatchesCreated ?? 0
        windowsNotQueued = stats?.uploadWindowsNotQueued ?? 0
        self.state = state
    }

    var totalParts: Int { batchesQueued + windowsNotQueued + 1 }
    var acknowledgedBatches: Int { state.acknowledgedBatches.filter { (0..<batchesQueued).contains($0) }.count }
    var sentParts: Int { acknowledgedBatches + (state.stopAcknowledged ? 1 : 0) }
    var isComplete: Bool { sentParts == totalParts }
    /// Floor, so 100 only when complete.
    var percent: Int { sentParts * 100 / totalParts }
    var rejectedParts: Int { state.failedBatches + (state.stopFailed ? 1 : 0) }
    /// The Stop copy is neither sent, queued nor rejected: it could not be queued (full disk).
    var stopMissing: Bool { !state.stopAcknowledged && !state.stopPending && !state.stopFailed }
    /// Parts the live upload will never send: only the laptop upload of the session folder fills them.
    var partsNeverQueued: Int { windowsNotQueued + (stopMissing ? 1 : 0) }

    enum DeleteRefusal: LocalizedError, Equatable {
        case unreadable
        case stillQueued(Int)
        case rejected(Int)
        case notInCloud(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "This trip's session.json can't be read, so the app can't tell whether it is in the cloud."
            case .stillQueued(let n):
                return "\(n) part(s) of this trip haven't reached the cloud yet. Let the upload finish before deleting."
            case .rejected(let n):
                return "\(n) part(s) of this trip were rejected by the server and are in upload_failed. Retry them in Settings or upload the trip from a laptop before deleting."
            case .notInCloud(let n):
                return "\(n) part(s) of this trip are not known to be in the cloud. Upload the trip from a laptop before deleting it from the phone."
            }
        }
    }

    /// Nothing is deleted on the phone until the cloud has the whole trip: every batch and the Stop
    /// copy acknowledged, nothing queued or rejected, no window left out of the live upload.
    static func deleteRefusal(metadata: SessionMetadata?, state: UploadQueue.TripState) -> DeleteRefusal? {
        guard let metadata else { return .unreadable }
        if state.pendingItems > 0 { return .stillQueued(state.pendingItems) }
        if state.failedItems > 0 { return .rejected(state.failedItems) }
        let copy = TripCloudCopy(stats: metadata.stats, state: state)
        // A trip without stats was never stopped cleanly (recovered): it has no Stop copy.
        guard metadata.stats != nil, metadata.endedAtUtc != nil, copy.isComplete else {
            return .notInCloud(copy.totalParts - copy.sentParts)
        }
        return nil
    }
}
