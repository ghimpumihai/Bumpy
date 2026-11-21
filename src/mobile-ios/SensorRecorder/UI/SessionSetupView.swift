import PhotosUI
import SwiftUI
import UIKit

/// Screen 2: session metadata (spec §3.8) with sensible defaults + mount photo.
struct SessionSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showCamera = false
    @State private var libraryItem: PhotosPickerItem?
    /// Decoded once per photo (a 12 MP JPEG must not be decoded on every re-render while typing).
    @State private var thumbnail: UIImage?
    /// JPEG encoding of the picked photo runs off the main thread (12 MP: hundreds of ms).
    @State private var photoTask: Task<Void, Never>?

    private let vehicleTypes = ["car", "bus", "tram", "bike", "boat"]
    private let mountPresets = ["taped flat on center console", "clamped in cup holder mount", "dashboard suction mount",
                                "air-vent mount (wobbly!)", "on rear seat floor"]
    private let orientationPresets = ["screen up, top of phone pointing to vehicle front",
                                      "screen up, top of phone pointing to vehicle rear",
                                      "portrait, screen facing driver",
                                      "landscape, screen facing driver"]
    private let carSeats = ["driver", "front passenger", "rear left", "rear middle", "rear right"]
    private let transitSeats = ["front of vehicle", "middle of vehicle", "rear of vehicle", "over front axle",
                                "over rear axle", "standing area"]
    private let weather = ["dry", "wet", "rain", "snow", "fog"]

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Vehicle") {
                Picker("Type", selection: $model.setup.vehicle.type) {
                    ForEach(vehicleTypes, id: \.self) { Text($0) }
                }
                TextField("Make / model (e.g. Porsche Taycan)", text: $model.setup.vehicle.makeModel)
                    .accessibilityIdentifier("vehicleMakeModel")
                if model.setup.vehicle.isPublicTransport {
                    TextField("Line number (e.g. 24B)", text: Binding(
                        get: { model.setup.vehicle.line ?? "" },
                        set: { model.setup.vehicle.line = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }))
                        .accessibilityIdentifier("vehicleLine")
                }
                TextField("Vehicle notes", text: $model.setup.vehicle.notes)
            }

            Section {
                Picker("Location", selection: $model.setup.mount.location) {
                    ForEach(withCurrent(mountPresets, model.setup.mount.location), id: \.self) { Text($0) }
                }
                Picker("Orientation", selection: $model.setup.mount.phoneOrientation) {
                    ForEach(withCurrent(orientationPresets, model.setup.mount.phoneOrientation), id: \.self) { Text($0) }
                }
                Toggle("Rigid mount", isOn: $model.setup.mount.rigid)
                Toggle("Hand-held (no mount)", isOn: $model.setup.mount.handheld)
                    .accessibilityIdentifier("handheldToggle")
                Toggle("Seat over an axle", isOn: $model.setup.mount.seatOverAxle)
                mountPhotoRow
            } header: {
                Text("Mount")
            } footer: {
                Text("Best: taped or clamped flat on the center console, screen up, top of phone toward the vehicle front. Never move it during the drive. A hand-held or non-rigid trip still counts for motion sickness, but not for road roughness or potholes.")
            }

            Section("People") {
                Picker("Operator seat", selection: $model.setup.people.operatorSeat) {
                    ForEach(withCurrent(seats.filter { $0 != "driver" }, model.setup.people.operatorSeat), id: \.self) { Text($0) }
                }
                Picker("Passenger seat (sickness)", selection: $model.setup.people.raterSeat) {
                    ForEach(withCurrent(seats, model.setup.people.raterSeat), id: \.self) { Text($0) }
                }
                Picker("Passenger posture", selection: $model.setup.people.raterPosture) {
                    ForEach(SessionMetadata.People.postures, id: \.self) { Text($0) }
                }
                .accessibilityIdentifier("raterPosture")
                TextField("Rater name / id (optional)", text: $model.setup.people.raterName)
                Stepper("Passengers: \(model.setup.people.passengerCount)", value: $model.setup.people.passengerCount, in: 1...60)
            }

            Section("Conditions") {
                Picker("Weather", selection: $model.setup.conditions.weather) {
                    ForEach(weather, id: \.self) { Text($0) }
                }
                TextField("Notes", text: $model.setup.conditions.notes)
            }

            Section {
                Toggle("Record audio", isOn: $model.setup.audioEnabled)
                    .accessibilityIdentifier("audioToggle")
            } header: {
                Text("Audio")
            } footer: {
                Text(model.setup.audioEnabled
                     ? "Road noise is recorded to the phone (never sent live; only in the session folder/export). Tell everyone in the vehicle."
                     : "Audio recording OFF: only the sound level (numbers) is measured; nothing from the microphone is stored. Default on bus and tram (other passengers, GDPR).")
            }
        }
        .navigationTitle("Session setup")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                SetupDefaults.save(model.setup)
                model.path.append(Route.preflight)
            } label: {
                Text("Continue to preflight").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.onBright) // contrast on accent blue
            .disabled(photoTask != nil) // the photo must be in the setup before the session is created
            .padding()
            .background(.ultraThinMaterial)
            .accessibilityIdentifier("setupContinue")
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                setMountPhoto { image.jpegData(compressionQuality: Self.jpegQuality) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: model.setup.vehicle.type) { _, _ in
            model.setup.applyVehicleTypeDefaults()
        }
        // Runs on appear and whenever the photo changes; cancelled if it changes again meanwhile.
        .task(id: model.setup.mountPhotoJPEG) {
            let data = model.setup.mountPhotoJPEG
            let thumb = await Task.detached(priority: .userInitiated) { Self.makeThumbnail(data) }.value
            if !Task.isCancelled { thumbnail = thumb }
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            setMountPhoto {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
                return UIImage(data: data)?.jpegData(compressionQuality: Self.jpegQuality)
            }
        }
    }

    nonisolated private static let jpegQuality: CGFloat = 0.8

    /// Decodes/encodes the photo on a background task; the newest pick wins if the user picks again.
    private func setMountPhoto(_ produce: @escaping @Sendable () async -> Data?) {
        photoTask?.cancel()
        photoTask = Task {
            let jpeg = await Task.detached(priority: .userInitiated) { await produce() }.value
            guard !Task.isCancelled else { return }
            if let jpeg { model.setup.mountPhotoJPEG = jpeg }
            photoTask = nil
        }
    }

    @ViewBuilder private var mountPhotoRow: some View {
        HStack {
            if let img = thumbnail {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipped().cornerRadius(6)
                Text("Mount photo ✓").foregroundStyle(Theme.ok)
            } else {
                Image(systemName: "camera").frame(width: 56, height: 56)
                Text("Mount photo (recommended)").foregroundStyle(.secondary)
            }
            Spacer()
            if photoTask != nil { ProgressView().accessibilityLabel("Processing photo") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(model.setup.mountPhotoJPEG == nil ? "Take" : "Retake") { showCamera = true }
                    .buttonStyle(.bordered)
            } else {
                PhotosPicker(selection: $libraryItem, matching: .images) { Text("Choose") }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Nonisolated: runs on a background task (a 12 MP decode must not block the main thread).
    nonisolated static func makeThumbnail(_ data: Data?) -> UIImage? {
        guard let data, let img = UIImage(data: data) else { return nil }
        return img.preparingThumbnail(of: CGSize(width: 168, height: 168)) ?? img
    }

    private var seats: [String] { model.setup.vehicle.isPublicTransport ? transitSeats : carSeats }

    private func withCurrent(_ presets: [String], _ current: String) -> [String] {
        presets.contains(current) || current.isEmpty ? presets : [current] + presets
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
