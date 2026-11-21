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
    @State private var cloud: TripCloudCopy?

    private var summary: TripSummary { TripSummary(metadata: metadata) }

    var body: some View {
        let summary = self.summary
        VStack(alignment: .leading, spacing: 24) {
            CircleIconButton(systemName: "line.3.horizontal", label: "Menu", id: "menuButton", action: openMenu)
                .padding(.leading, -4)

            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text("Trip saved")
                    .font(Theme.font(40, .semibold))
                    .tracking(-1.2)
                    .foregroundStyle(Theme.text)
                Text(subtitle(summary))
                    .font(Theme.font(17))
                    .foregroundStyle(Theme.muted)
            }
            .riseIn(0.1)

            if let q = summary.qualityPercent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(shownQuality) %")
                        .font(Theme.font(72, .semibold))
                        .tracking(-3)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(summary.isPoor ? Theme.problem : Theme.text)
                    Text("Data quality")
                        .font(Theme.font(17, .semibold))
                        .foregroundStyle(Theme.text)
                    if let problem = summary.problem {
                        Text(problem)
                            .font(Theme.font(15))
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
                    .font(Theme.font(17))
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
            let percent = cloud?.percent
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Trip in the cloud").font(Theme.font(15)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(percent ?? 0) %")
                        .font(Theme.font(28, .semibold))
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
                if let warning = uploadWarning {
                    // Upload problems are WARN at most: the data is safe on disk.
                    Text(warning)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.warn)
                } else {
                    Text(cloud?.isComplete == true ? "Complete. The web shows the whole trip."
                                                   : "The rest is saved on this phone and uploads when you have signal.")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.muted)
                }
            }
            .animation(.easeOut(duration: 0.8), value: percent)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("uploadProgress")
        } else {
            Text("Upload off · the trip is kept on this phone")
                .font(Theme.font(13))
                .foregroundStyle(Theme.muted)
                .accessibilityIdentifier("uploadProgress")
        }
    }

    /// Parts the live upload will not deliver by itself: say what the operator has to do.
    private var uploadWarning: String? {
        guard let cloud else { return nil }
        var parts: [String] = []
        if cloud.partsNeverQueued > 0 {
            parts.append("\(cloud.partsNeverQueued) part(s) of this trip never went into the live upload.")
        }
        if cloud.rejectedParts > 0 {
            parts.append("\(cloud.rejectedParts) part(s) were rejected by the server; retry them in Settings.")
        }
        guard !parts.isEmpty else { return nil }
        return (parts + ["Everything is kept on this phone: upload the trip from a laptop so the web has all of it."])
            .joined(separator: " ")
    }

    private func pollUpload() async {
        let queue = app.uploadQueue, id = metadata.sessionId, stats = metadata.stats
        while !Task.isCancelled {
            // Directory listing and the ack record: never on the main thread.
            let state = await Task.detached(priority: .utility) { queue.tripState(sessionId: id) }.value
            cloud = TripCloudCopy(stats: stats, state: state)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func subtitle(_ summary: TripSummary) -> String {
        var parts: [String] = []
        if let start = ISO8601.date(metadata.startedAtUtc) {
            // "Today, 14:05" (relative day, then the time).
            let day = DateFormatter()
            day.dateStyle = .medium
            day.timeStyle = .none
            day.doesRelativeDateFormatting = true
            let time = DateFormatter()
            time.dateStyle = .none
            time.timeStyle = .short
            parts.append(day.string(from: start) + ", " + time.string(from: start))
        }
        parts.append(TripFormat.duration(summary.durationSec))
        let meters = TripSummary.distanceMeters(trackPoints)
        if meters > 0 { parts.append(TripFormat.distance(meters)) }
        return parts.joined(separator: " · ")
    }
}
