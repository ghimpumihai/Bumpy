import SwiftUI

/// After the trip: is the data good, and how much of it reached the cloud. Everything computed in
/// the cloud (roughness, potholes, sickness) lives on the web dashboard only (D51).
struct RecapView: View {
    let metadata: SessionMetadata
    let trackPoints: [TrackBuffer.Point]
    var openMenu: () -> Void
    var onDone: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var shownQuality = 0
    @State private var counts: (pending: Int, failed: Int)?

    private var summary: TripSummary { TripSummary(metadata: metadata) }

    var body: some View {
        let summary = self.summary
        VStack(alignment: .leading, spacing: 24) {
            CircleIconButton(systemName: "line.3.horizontal", label: "Menu", id: "menuButton", action: openMenu)
                .padding(.leading, -4)

            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text("Trip saved")
                    .font(.system(size: 40, weight: .semibold))
                    .tracking(-1.2)
                    .foregroundStyle(Theme.text)
                Text(subtitle(summary))
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.muted)
            }
            .riseIn(0.1)

            if let q = summary.qualityPercent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(shownQuality) %")
                        .font(.system(size: 72, weight: .semibold))
                        .tracking(-3)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(summary.isPoor ? Theme.problem : Theme.text)
                    Text("Data quality")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let problem = summary.problem {
                        Text(problem)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.problem)
                    }
                }
                .padding(.top, 16)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dataQuality")
                .riseIn(0.2)
                .task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    withAnimation(.easeOut(duration: 1.1)) { shownQuality = q }
                }
            }
            Spacer()

            if let url = AppSettings.dashboardURL?.appendingPathComponent("sessions/\(metadata.sessionId)") {
                Button { openURL(url) } label: {
                    HStack {
                        Text("See the trip on the web")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
                    .frame(minHeight: 56)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("openTripOnWeb")
                .riseIn(0.28)
            }

            VStack(alignment: .leading, spacing: 10) {
                uploadBlock
                Button("Done", action: onDone)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 6)
                    .accessibilityIdentifier("recapDone")
            }
            .riseIn(0.34)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.background)
        .task { await pollUpload() }
    }

    @ViewBuilder private var uploadBlock: some View {
        if AppSettings.uploadConfig.isEnabled {
            let percent = uploadPercent
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Trip in the cloud").font(.system(size: 15)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(percent ?? 0) %")
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.text)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(Theme.ink).frame(width: g.size.width * CGFloat(percent ?? 0) / 100)
                    }
                }
                .frame(height: 4)
                if rejected > 0 {
                    // Upload problems are WARN at most: the data is safe on disk.
                    Text("\(rejected) part(s) were rejected by the server. They are kept on this phone.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.warn)
                } else {
                    Text(percent == 100 ? "Complete. The web shows the whole trip."
                                        : "The rest is saved on this phone and uploads when you have signal.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
            }
            .animation(.easeOut(duration: 0.8), value: percent)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("uploadProgress")
        } else {
            Text("Upload off · the trip is kept on this phone")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .accessibilityIdentifier("uploadProgress")
        }
    }

    private var rejected: Int { counts?.failed ?? 0 }

    /// Share of this trip's batches accepted by the server. Rejected ones count as not sent, so the
    /// line never says "Complete" for a trip the backend refused.
    private var uploadPercent: Int? {
        guard let counts else { return nil }
        let created = metadata.stats?.uploadBatchesCreated ?? 0
        guard created > 0 else { return counts.pending + counts.failed == 0 ? 100 : 0 }
        let sent = max(0, created - counts.pending - counts.failed)
        return min(100, sent * 100 / created)
    }

    private func pollUpload() async {
        let queue = app.uploadQueue, id = metadata.sessionId
        while !Task.isCancelled {
            // Directory listing: never on the main thread.
            let c = await Task.detached(priority: .utility) { queue.batchCounts(sessionId: id) }.value
            counts = c
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func subtitle(_ summary: TripSummary) -> String {
        var parts: [String] = []
        if let start = ISO8601.date(metadata.startedAtUtc) {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            parts.append(f.string(from: start))
        }
        parts.append(TripFormat.duration(summary.durationSec))
        let meters = TripSummary.distanceMeters(trackPoints)
        if meters > 0 { parts.append(TripFormat.distance(meters)) }
        return parts.joined(separator: " · ")
    }
}
