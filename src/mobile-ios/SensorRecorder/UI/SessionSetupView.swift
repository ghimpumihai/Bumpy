import PhotosUI
import SwiftUI
import UIKit

/// Screen 2: session metadata (spec §3.8) with sensible defaults + mount photo.
struct SessionSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showCamera = false
    @State private var libraryItem: PhotosPickerItem?

    private let vehicleTypes = ["car", "bus", "tram", "bike", "boat"]
    private let mountPresets = ["taped flat on center console", "clamped in cup holder mount", "dashboard suction mount",
                                "air-vent mount (wobbly!)", "on rear seat floor"]
    private let orientationPresets = ["screen up, top of phone pointing to vehicle front",
                                      "screen up, top of phone pointing to vehicle rear",
                                      "portrait, screen facing driver",
                                      "landscape, screen facing driver"]
    private let seats = ["driver", "front passenger", "rear left", "rear middle", "rear right"]
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
                mountPhotoRow
            } header: {
                Text("Mount")
            } footer: {
                Text("Best: taped or clamped flat on the center console, screen up, top of phone toward the vehicle front. Never move it during the drive.")
            }

            Section("People") {
                Picker("Operator seat", selection: $model.setup.people.operatorSeat) {
                    ForEach(seats.filter { $0 != "driver" }, id: \.self) { Text($0) }
                }
                Picker("Sickness rater seat", selection: $model.setup.people.raterSeat) {
                    ForEach(seats, id: \.self) { Text($0) }
                }
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
                Label("Audio is recorded locally for road-noise analysis. Tell everyone in the car.", systemImage: "mic.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
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
            .padding()
            .background(.ultraThinMaterial)
            .accessibilityIdentifier("setupContinue")
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                model.setup.mountPhotoJPEG = image.jpegData(compressionQuality: 0.8)
            }
            .ignoresSafeArea()
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    model.setup.mountPhotoJPEG = img.jpegData(compressionQuality: 0.8)
                }
            }
        }
    }

    @ViewBuilder private var mountPhotoRow: some View {
        HStack {
            if let data = model.setup.mountPhotoJPEG, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipped().cornerRadius(6)
                Text("Mount photo ✓").foregroundStyle(Theme.ok)
            } else {
                Image(systemName: "camera").frame(width: 56, height: 56)
                Text("Mount photo (recommended)").foregroundStyle(.secondary)
            }
            Spacer()
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(model.setup.mountPhotoJPEG == nil ? "Take" : "Retake") { showCamera = true }
                    .buttonStyle(.bordered)
            } else {
                PhotosPicker(selection: $libraryItem, matching: .images) { Text("Choose") }
                    .buttonStyle(.bordered)
            }
        }
    }

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
