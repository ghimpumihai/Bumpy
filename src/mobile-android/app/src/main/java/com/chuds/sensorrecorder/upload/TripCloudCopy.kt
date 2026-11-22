package com.chuds.sensorrecorder.upload

import com.chuds.sensorrecorder.core.SessionMetadata

/**
 * How much of one trip is known to be in the cloud (D55): every batch the trip queued, the 2 s windows
 * that never entered the queue, and the Stop copy each count as one part. Only parts the backend
 * acknowledged count as sent, so "complete" means the cloud has the whole trip.
 */
class TripCloudCopy(stats: SessionMetadata.Stats?, private val state: UploadQueue.TripState) {
    private val batchesQueued = stats?.uploadBatchesCreated ?: 0
    private val windowsNotQueued = stats?.uploadWindowsNotQueued ?: 0

    val totalParts: Int get() = batchesQueued + windowsNotQueued + 1
    private val acknowledgedBatches: Int get() = state.acknowledgedBatches.count { it in 0 until batchesQueued }
    val sentParts: Int get() = acknowledgedBatches + if (state.stopAcknowledged) 1 else 0
    val isComplete: Boolean get() = sentParts == totalParts

    /** Floor, so 100 only when complete. */
    val percent: Int get() = sentParts * 100 / totalParts
    val rejectedParts: Int get() = state.failedBatches + if (state.stopFailed) 1 else 0

    /** The Stop copy is neither sent, queued nor rejected: it could not be queued (full disk). */
    val stopMissing: Boolean get() = !state.stopAcknowledged && !state.stopPending && !state.stopFailed

    /** Parts the live upload will never send: only the laptop upload of the session folder fills them. */
    val partsNeverQueued: Int get() = windowsNotQueued + if (stopMissing) 1 else 0

    sealed class DeleteRefusal(message: String) : Exception(message) {
        class Unreadable : DeleteRefusal("This trip's session.json can't be read, so the app can't tell whether it is in the cloud.")
        class StillQueued(val parts: Int) :
            DeleteRefusal("$parts part(s) of this trip haven't reached the cloud yet. Let the upload finish before deleting.")
        class Rejected(val parts: Int) : DeleteRefusal(
            "$parts part(s) of this trip were rejected by the server and are in upload_failed. " +
                "Retry them in Settings or upload the trip from a laptop before deleting.",
        )
        class NotInCloud(val parts: Int) : DeleteRefusal(
            "$parts part(s) of this trip are not known to be in the cloud. Upload the trip from a laptop before deleting it from the phone.",
        )
    }

    companion object {
        /**
         * Nothing is deleted on the phone until the cloud has the whole trip: every batch and the Stop copy
         * acknowledged, nothing queued or rejected, no window left out of the live upload.
         */
        fun deleteRefusal(metadata: SessionMetadata?, state: UploadQueue.TripState): DeleteRefusal? {
            if (metadata == null) return DeleteRefusal.Unreadable()
            if (state.pendingItems > 0) return DeleteRefusal.StillQueued(state.pendingItems)
            if (state.failedItems > 0) return DeleteRefusal.Rejected(state.failedItems)
            val copy = TripCloudCopy(metadata.stats, state)
            // A trip without stats was never stopped cleanly (recovered): it has no Stop copy.
            if (metadata.stats == null || metadata.endedAtUtc == null || !copy.isComplete) {
                return DeleteRefusal.NotInCloud(copy.totalParts - copy.sentParts)
            }
            return null
        }
    }
}
