import MapKit
import SwiftUI

/// Screen 4: the live health dashboard + labeling panel (spec §7). One glance answers
/// "is everything recording correctly right now?"
struct RecordingDashboardView: View {
    let controller: RecordingController
    @State private var showNote = false
    @State private var showIssues = false
    /// Kept here (not in the sheet) so a sickness prompt closing the sheet doesn't lose the text.
    @State private var noteDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(controller: controller)
            HealthBanner(controller: controller) { showIssues = true }
            ScrollView {
                VStack(spacing: 10) {
                    StreamTable(controller: controller)
                    LivePlots(controller: controller)
                    TrackMapSection(controller: controller)
                    EstimatesRow(controller: controller)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            // The prompt covers only the middle area: label buttons and hold-to-stop stay usable.
            .overlay { SicknessOverlay(controller: controller) }
            LabelPanel(controller: controller, showNote: $showNote)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .top) { ToastView(controller: controller) }
        .sheet(isPresented: $showNote) { NoteSheet(controller: controller, text: $noteDraft) }
        .sheet(isPresented: $showIssues) { IssuesSheet(controller: controller) }
        .onChange(of: controller.sicknessPromptActive) { _, active in
            // Sheets are drawn above the dashboard: close them so the rater sees the prompt.
            if active { showNote = false; showIssues = false }
        }
        .persistentSystemOverlays(.hidden)
    }
}

// MARK: - Header & banner

private struct HeaderBar: View {
    let controller: RecordingController
    @State private var blink = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.problem).frame(width: 14, height: 14).opacity(blink ? 0.25 : 1)
                .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { blink = true } }
            Text("REC").font(Theme.mono(18, weight: .bold)).foregroundStyle(Theme.problem)
            Text(DurationFormat.hms(controller.snapshot.elapsed))
                .font(Theme.mono(22, weight: .bold)).foregroundStyle(Theme.onSurface)
                .accessibilityIdentifier("elapsed")
            Spacer()
            if controller.session.isSynthetic {
                Text("SYNTH").font(.caption2.bold()).foregroundStyle(Theme.neutral)
            }
            Text("session \(controller.session.shortId)").font(Theme.mono(14)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }
}

private struct HealthBanner: View {
    let controller: RecordingController
    var onTap: () -> Void

    var body: some View {
        let level = controller.overall
        let issues = controller.issues
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text(level == .ok ? "ALL STREAMS OK" : (level == .warn ? "WARNING" : "PROBLEM"))
                    .font(.system(size: 24, weight: .heavy))
                if let first = issues.first {
                    Text(first.message + (issues.count > 1 ? "  (+\(issues.count - 1) more)" : ""))
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(level == .problem ? Theme.onSurface : Theme.onBright)
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.horizontal, 8)
            .background(Theme.color(level))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("banner")
        .accessibilityValue(level.label)
    }
}

private struct IssuesSheet: View {
    let controller: RecordingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if controller.issues.isEmpty { Text("No issues. All streams OK.").foregroundStyle(Theme.ok) }
                ForEach(controller.issues, id: \.key) { i in
                    HStack {
                        StatusDot(color: Theme.color(i.level))
                        Text(i.message)
                    }
                }
            }
            .navigationTitle("Health")
            .toolbar { Button("Close") { dismiss() } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Stream table

private struct StreamTable: View {
    let controller: RecordingController

    var body: some View {
        let snap = controller.snapshot
        VStack(spacing: 0) {
            HStack {
                Text("STREAM").frame(width: 104, alignment: .leading)
                Text("RATE").frame(width: 78, alignment: .trailing)
                Text("SAMPLES").frame(maxWidth: .infinity, alignment: .trailing)
                Text("AGE").frame(width: 42, alignment: .trailing)
                Text("●").frame(width: 16)
            }
            .font(Theme.mono(11, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            ForEach(snap.rows) { row in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(row.name).frame(width: 104, alignment: .leading).lineLimit(1)
                        Text(row.rate).frame(width: 78, alignment: .trailing).lineLimit(1)
                        Text(row.samples).frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.6)
                        Text(row.age).frame(width: 42, alignment: .trailing)
                        dot(row.dot).frame(width: 16)
                    }
                    .font(Theme.mono(13, weight: .medium))
                    if let d = row.detail {
                        Text(d).font(Theme.mono(11)).foregroundStyle(.secondary).padding(.leading, 8)
                    }
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Self.statusText(row.dot))
                .accessibilityIdentifier("row.\(row.id)")
                Divider().overlay(Theme.hairline)
            }
            HStack {
                StatusDot(color: Theme.color(snap.deviceLevel), size: 10)
                Text(snap.deviceLine).font(Theme.mono(12)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    static func statusText(_ d: StreamRowModel.Dot) -> String {
        switch d {
        case .neutral: return "not applicable"
        case .level(let l): return l.label
        }
    }

    @ViewBuilder private func dot(_ d: StreamRowModel.Dot) -> some View {
        switch d {
        case .neutral: StatusDot(color: Theme.neutral, size: 12)
        case .level(let l): StatusDot(color: Theme.color(l), size: 12)
        }
    }
}

// MARK: - Plots

private struct LivePlots: View {
    let controller: RecordingController

    var body: some View {
        let s = controller.snapshot
        HStack(spacing: 8) {
            PlotView(title: "Vertical · 10 s", values: s.vertical, color: Theme.accent, minRange: 0.05, unit: "g")
            PlotView(title: "Lateral sway · 60 s", values: s.lateral, color: Theme.warn, minRange: 0.02, unit: "g")
        }
    }
}

/// Min/max envelope per pixel column, so short spikes (potholes) are never decimated away.
struct PlotView: View {
    let title: String
    let values: [Double]
    let color: Color
    let minRange: Double
    let unit: String

    var body: some View {
        let peak = max(minRange, values.map(abs).max() ?? 0)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "±%.2f %@", peak, unit)).font(Theme.mono(11)).foregroundStyle(.secondary)
            }
            Canvas { ctx, size in
                let mid = size.height / 2
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: mid)); zero.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(zero, with: .color(Theme.plotZeroLine), lineWidth: 1)
                guard values.count > 1 else { return }
                let cols = max(1, Int(size.width))
                let perCol = Double(values.count) / Double(cols)
                var path = Path()
                for c in 0..<cols {
                    let lo = Int(Double(c) * perCol)
                    let hi = min(values.count, max(lo + 1, Int(Double(c + 1) * perCol)))
                    guard lo < hi else { continue }
                    var mn = values[lo], mx = values[lo]
                    for k in lo..<hi { mn = min(mn, values[k]); mx = max(mx, values[k]) }
                    let x = CGFloat(c) + 0.5
                    let y1 = mid - CGFloat(mx / peak) * (mid - 2)
                    let y2 = mid - CGFloat(mn / peak) * (mid - 2)
                    path.move(to: CGPoint(x: x, y: y1))
                    path.addLine(to: CGPoint(x: x, y: max(y2, y1 + 1)))
                }
                ctx.stroke(path, with: .color(color), lineWidth: 1.2)
            }
            .frame(height: 70)
            .background(Theme.plotBackground)
        }
        .padding(8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Map

private struct TrackMapSection: View {
    let controller: RecordingController

    var body: some View {
        // Reads only `trackPoints` (updated ≤ 1 Hz), so the map is not re-rendered at 8 Hz.
        TrackMapView(points: controller.trackPoints)
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct TrackMapView: View, Equatable {
    let points: [TrackBuffer.Point]
    @State private var position: MapCameraPosition = .automatic
    @State private var lastFollow = Date.distantPast

    static func == (a: TrackMapView, b: TrackMapView) -> Bool { a.points == b.points }

    /// Polyline vertices drawn at most (older track is thinned; the recorded data is untouched).
    static let maxDrawnPoints = 1500

    /// Keeps every point of the newest stretch and thins the rest evenly, always keeping the last point.
    static func decimate(_ pts: [TrackBuffer.Point], max n: Int = maxDrawnPoints) -> [TrackBuffer.Point] {
        guard pts.count > n, n >= 2 else { return pts }
        let recent = n / 2
        let old = pts.dropLast(recent)
        let step = Double(old.count) / Double(n - recent)
        var out: [TrackBuffer.Point] = []
        out.reserveCapacity(n)
        var i = 0.0
        while Int(i) < old.count { out.append(old[old.startIndex + Int(i)]); i += step }
        out.append(contentsOf: pts.suffix(recent))
        return out
    }

    struct Segment: Identifiable {
        let id: Int
        let coords: [CLLocationCoordinate2D]
        let color: Color
    }

    /// Consecutive points with the same speed bucket form one polyline (sharing the boundary point).
    static func segments(_ pts: [TrackBuffer.Point]) -> [Segment] {
        guard pts.count >= 2 else { return [] }
        func bucket(_ mps: Double) -> Int {
            let kmh = mps * 3.6
            switch kmh {
            case ..<10: return 0
            case ..<30: return 1
            case ..<50: return 2
            case ..<80: return 3
            default: return 4
            }
        }
        let colors = Theme.speedBuckets
        var out: [Segment] = []
        var current = [CLLocationCoordinate2D(latitude: pts[0].lat, longitude: pts[0].lon)]
        var b = bucket(pts[1].speed)
        for p in pts.dropFirst() {
            let c = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
            let nb = bucket(p.speed)
            current.append(c)
            if nb != b {
                out.append(Segment(id: out.count, coords: current, color: colors[b]))
                current = [c]
                b = nb
            }
        }
        if current.count >= 2 { out.append(Segment(id: out.count, coords: current, color: colors[b])) }
        return out
    }

    /// Re-centre at most every 10 s (each camera move loads tiles over cellular).
    private func follow() {
        guard let p = points.last, Date().timeIntervalSince(lastFollow) >= 10 else { return }
        lastFollow = Date()
        position = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                                     distance: 1800))
    }

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(Self.segments(Self.decimate(points))) { seg in
                MapPolyline(coordinates: seg.coords).stroke(seg.color, lineWidth: 4)
            }
            if let p = points.last {
                // Current position = last recorded fix (not the live user location).
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)) {
                    Circle().fill(Theme.onSurface).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 3))
                }
            }
        }
        .onAppear { follow() }
        .onChange(of: points.last) { _, _ in follow() } // count freezes at the buffer cap; last doesn't
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .overlay(alignment: .topLeading) {
            Text("Track · colored by speed").font(.caption2.bold()).padding(4)
                .background(Theme.mapLabelBackground, in: RoundedRectangle(cornerRadius: 4)).padding(6)
        }
    }
}

private struct EstimatesRow: View {
    let controller: RecordingController

    var body: some View {
        let s = controller.snapshot
        HStack {
            VStack(alignment: .leading) {
                Text("Roughness now").font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.2f m/s²", s.roughness)).font(Theme.mono(15, weight: .bold))
            }
            Spacer()
            VStack(alignment: .leading) {
                Text("MSDV so far").font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.2f", s.msdv)).font(Theme.mono(15, weight: .bold))
            }
            Spacer()
            VStack(alignment: .leading) {
                Text("Last MISC").font(.caption2).foregroundStyle(.secondary)
                Text(s.lastSickness.map(String.init) ?? "–").font(Theme.mono(15, weight: .bold))
                    .foregroundStyle(s.lastSickness.map(MISC.color) ?? Theme.onSurface)
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            Text("on-device estimates").font(.system(size: 9)).foregroundStyle(.tertiary).padding(4)
        }
    }
}

// MARK: - Label panel

private struct LabelPanel: View {
    let controller: RecordingController
    @Binding var showNote: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                BigButton(title: "POTHOLE", color: Theme.labelPothole, id: "label.pothole") {
                    controller.label(.pothole, toastText: "Pothole logged")
                }
                BigButton(title: "SPEED BUMP", color: Theme.labelSpeedBump, textColor: Theme.onBright, id: "label.speedBump") {
                    controller.label(.speedBump, toastText: "Speed bump logged")
                }
                BigButton(title: "PHONE MOVED", color: Theme.labelPhoneMoved, id: "label.phoneMoved") {
                    controller.label(.phoneMoved, toastText: "PHONE MOVED logged (data invalid)")
                }
            }
            ToggleRow(title: "Surface") {
                ForEach(SurfaceKind.allCases) { s in
                    ToggleChip(title: s.shortName, active: controller.activeSurface == s, id: "surface.\(s.rawValue)") {
                        controller.toggleSurface(s)
                    }
                }
            }
            ToggleRow(title: "Segment") {
                ForEach(SegmentKind.allCases) { s in
                    ToggleChip(title: s.shortName, active: controller.activeSegments.contains(s), id: "segment.\(s.rawValue)") {
                        controller.toggleSegment(s)
                    }
                }
            }
            HStack(spacing: 6) {
                SmallButton(title: "SICKNESS 0–10", id: "sicknessButton") { controller.openManualSickness() }
                SmallButton(title: "SYNC TAP", id: "syncTap") {
                    controller.label(.syncTap, toastText: "SYNC: knock firmly 3× now")
                }
                SmallButton(title: "NOTE", id: "noteButton") { showNote = true }
                HoldToStopButton { controller.stop() }
            }
        }
        .padding(8)
        .background(Theme.panel.ignoresSafeArea(edges: .bottom))
    }
}

private struct BigButton: View {
    let title: String
    let color: Color
    var textColor: Color = Theme.onSurface
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .heavy))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 60)
                .foregroundStyle(textColor)
                .background(color, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier(id)
    }
}

private struct SmallButton: View {
    let title: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(Theme.onSurface)
                .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier(id)
    }
}

private struct ToggleRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                .fixedSize().rotationEffect(.degrees(-90)).frame(width: 14, height: 44)
                .accessibilityHidden(true)
            content
        }
    }
}

private struct ToggleChip: View {
    let title: String
    let active: Bool
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(active ? Theme.onBright : Theme.onSurface)
                .background(active ? Theme.ok : Theme.panelHigh, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Theme.onSurface : .clear, lineWidth: 2))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier(id)
        .accessibilityValue(active ? "active" : "inactive")
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? 0.15 : 0)
    }
}

/// Stop needs a 2 s long-press (spec §8): no accidental stop, no pause.
struct HoldToStopButton: View {
    let action: () -> Void
    @State private var pressing = false
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.25))
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 10).fill(Theme.problem)
                    .frame(width: g.size.width * progress)
            }
            Text(pressing ? "HOLD…" : "HOLD 2 s\nTO STOP ■")
                .font(.system(size: 12, weight: .heavy))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .foregroundStyle(Theme.onSurface)
        }
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 2, maximumDistance: 40) {
            progress = 0
            pressing = false
            action()
        } onPressingChanged: { p in
            pressing = p
            withAnimation(p ? .linear(duration: 2) : .easeOut(duration: 0.15)) { progress = p ? 1 : 0 }
        }
        .accessibilityElement()
        .accessibilityLabel("Hold for two seconds to stop recording")
        .accessibilityIdentifier("holdToStop")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Toast, sickness prompt, note

private struct ToastView: View {
    let controller: RecordingController

    var body: some View {
        if let t = controller.toast {
            Text(t)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.toastForeground)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.toastBackground, in: Capsule())
                .shadow(radius: 8)
                .padding(.top, 110)
                .transition(.opacity)
                .accessibilityIdentifier("toast")
                .allowsHitTesting(false)
        }
    }
}

private struct SicknessOverlay: View {
    let controller: RecordingController

    var body: some View {
        if controller.sicknessPromptActive || controller.sicknessManualOpen {
            ZStack {
                Theme.scrim
                ScrollView {
                VStack(spacing: 10) {
                    Text("How do you feel?").font(.title.bold())
                    Text("MISC rating · rater: glance only").font(.subheadline).foregroundStyle(.secondary)
                    if controller.sicknessPromptActive {
                        Text("Auto-dismiss in \(controller.sicknessRemaining) s")
                            .font(Theme.mono(16, weight: .bold)).foregroundStyle(Theme.warn)
                            .accessibilityIdentifier("sicknessCountdown")
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(0...10, id: \.self) { v in
                            Button {
                                controller.rateSickness(v)
                            } label: {
                                HStack(spacing: 8) {
                                    Text("\(v)").font(.system(size: 28, weight: .heavy)).frame(width: 40)
                                    Text(MISC.labels[v]).font(.system(size: 12, weight: .semibold))
                                        .multilineTextAlignment(.leading).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .foregroundStyle(Theme.onBright)
                                .background(MISC.color(v), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .accessibilityIdentifier("misc.\(v)")
                        }
                    }
                    Text(MISC.symptomsNote).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if controller.sicknessPromptActive {
                        // Never force a fake rating: skipping is logged as a missed prompt.
                        Button("Skip (no rating)") { controller.skipSicknessPrompt() }
                            .font(.headline).padding(.top, 4)
                            .accessibilityIdentifier("sicknessSkip")
                    } else {
                        Button("Cancel") { controller.closeManualSickness() }
                            .font(.headline).padding(.top, 4)
                            .accessibilityIdentifier("sicknessCancel")
                    }
                }
                .padding()
                }
            }
        }
    }
}

private struct NoteSheet: View {
    let controller: RecordingController
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("What happened?", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focused)
                    .accessibilityIdentifier("noteField")
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { controller.label(.note, note: t, toastText: "Note logged") }
                        text = ""
                        dismiss()
                    }
                    .accessibilityIdentifier("noteSave")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
