import AppKit
@preconcurrency import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MirrorToolsStore {
    enum State: Equatable {
        case idle
        case requestingPermission
        case starting
        case running
        case denied
        case restricted
        case noCamera
        case failed
    }

    private(set) var state: State = .idle
    var isMirrored = true

    @ObservationIgnored private let capture = MirrorCaptureController()
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var isShutDown = false

    init() {}

    func start(context: ToolsContext) {
        guard !isShutDown, state != .running, state != .starting,
              state != .requestingPermission else { return }

        requestID += 1
        let currentRequest = requestID
        state = .requestingPermission

        Task { @MainActor [weak self] in
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let allowed: Bool
            switch status {
            case .authorized:
                allowed = true
            case .notDetermined:
                context.beginDialog()
                allowed = await AVCaptureDevice.requestAccess(for: .video)
                context.endDialog()
            case .denied:
                self?.finishPermission(.denied, requestID: currentRequest)
                return
            case .restricted:
                self?.finishPermission(.restricted, requestID: currentRequest)
                return
            @unknown default:
                self?.finishPermission(.failed, requestID: currentRequest)
                return
            }

            guard let self, self.requestID == currentRequest, !self.isShutDown else { return }
            guard allowed else {
                self.state = .denied
                return
            }

            self.state = .starting
            self.capture.start { [weak self] result in
                guard let self, self.requestID == currentRequest, !self.isShutDown else { return }
                switch result {
                case .success:
                    self.state = .running
                case .failure(.noCamera):
                    self.state = .noCamera
                case .failure(.configuration):
                    self.state = .failed
                }
            }
        }
    }

    func stop() {
        requestID += 1
        capture.stop()
        switch state {
        case .requestingPermission, .starting, .running:
            state = .idle
        case .idle, .denied, .restricted, .noCamera, .failed:
            break
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        requestID += 1
        state = .idle
        capture.shutdown()
    }

    fileprivate var session: AVCaptureSession { capture.session }

    private func finishPermission(_ newState: State, requestID currentRequest: Int) {
        guard requestID == currentRequest, !isShutDown else { return }
        state = newState
    }
}

@MainActor
struct MirrorToolsView: View {
    let store: MirrorToolsStore
    let context: ToolsContext

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick Mirror")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("A live look at your camera. Nothing is recorded or sent.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.56))
                    }

                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.black.opacity(0.8))

                        if store.state == .running || store.state == .starting {
                            MirrorPreview(session: store.session, isMirrored: store.isMirrored)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        if store.state != .running {
                            placeholder
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: max(140, geometry.size.height - 142))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    }

                    HStack(spacing: 12) {
                        Toggle("Mirror image", isOn: Bindable(store).isMirrored)
                            .toggleStyle(.switch)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                            .disabled(store.state != .running)

                        Spacer(minLength: 8)

                        if store.state == .running || store.state == .starting {
                            Button("Stop Camera") { store.stop() }
                                .accessibilityLabel("Stop camera preview")
                        } else {
                            Button("Start Camera") { store.start(context: context) }
                                .disabled(store.state == .requestingPermission || store.state == .restricted)
                                .accessibilityLabel("Start camera preview")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(red: 0.105, green: 0.111, blue: 0.124))
        .preferredColorScheme(.dark)
        .onDisappear { store.stop() }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 10) {
            if store.state == .requestingPermission || store.state == .starting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "web.camera")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(.white.opacity(0.52))
            }

            Text(placeholderTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Text(placeholderDetail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    private var placeholderTitle: String {
        switch store.state {
        case .idle: "Camera is off"
        case .requestingPermission: "Waiting for camera permission"
        case .starting: "Starting camera…"
        case .running: ""
        case .denied: "Camera access is off"
        case .restricted: "Camera access is restricted"
        case .noCamera: "No camera found"
        case .failed: "Couldn’t start the camera"
        }
    }

    private var placeholderDetail: String {
        switch store.state {
        case .idle: "Start Camera when you want a quick preview."
        case .requestingPermission: "Choose Allow in the macOS prompt to see your preview."
        case .starting: "Your preview will appear in a moment."
        case .running: ""
        case .denied: "Allow Knotch in System Settings → Privacy & Security → Camera, then try again."
        case .restricted: "Check your device’s camera restrictions."
        case .noCamera: "Connect or enable a camera, then try again."
        case .failed: "Check whether another app is using the camera, then try again."
        }
    }
}

private struct MirrorPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool

    func makeNSView(context: Context) -> MirrorPreviewView {
        MirrorPreviewView(session: session)
    }

    func updateNSView(_ view: MirrorPreviewView, context: Context) {
        view.setMirrored(isMirrored)
    }
}

private final class MirrorPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init(frame: .zero)
        wantsLayer = true
        setMirrored(true)
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { previewLayer }

    func setMirrored(_ mirrored: Bool) {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}

private enum MirrorCaptureError: Error, Sendable {
    case noCamera
    case configuration
}

/// The capture session is configured and started only on this serial queue.
/// AVFoundation's preview layer reads the session on the main thread.
private final class MirrorCaptureController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.knotch.mirror.capture", qos: .userInitiated)

    func start(completion: @escaping @MainActor @Sendable (Result<Void, MirrorCaptureError>) -> Void) {
        queue.async { [self] in
            guard let camera = AVCaptureDevice.default(for: .video) else {
                Task { @MainActor in completion(.failure(.noCamera)) }
                return
            }

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: camera)
            } catch {
                Task { @MainActor in completion(.failure(.configuration)) }
                return
            }

            session.beginConfiguration()
            session.sessionPreset = .high
            for oldInput in session.inputs { session.removeInput(oldInput) }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                Task { @MainActor in completion(.failure(.configuration)) }
                return
            }
            session.addInput(input)
            session.commitConfiguration()
            session.startRunning()

            let result: Result<Void, MirrorCaptureError> = session.isRunning
                ? .success(()) : .failure(.configuration)
            Task { @MainActor in completion(result) }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func shutdown() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
    }
}
