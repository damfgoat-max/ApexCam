import Foundation
import AVFoundation
import Photos
import UIKit
import CoreMotion

enum CameraPreset: String, CaseIterable, Identifiable {
    case auto = "Auto", sports = "Sports", portrait = "Portrait", night = "Night", vlog = "Vlog", macro = "Macro", video = "Video"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .sports: return "figure.run"
        case .portrait: return "person.crop.circle"
        case .night: return "moon.stars.fill"
        case .vlog: return "video.fill"
        case .macro: return "leaf.fill"
        case .video: return "film.fill"
        }
    }
    var blurb: String {
        switch self {
        case .auto: return "Everything automatic. Just point and shoot."
        case .sports: return "Fast shutter to freeze motion. Great for wrestling & action."
        case .portrait: return "Focus locks on faces and eyes."
        case .night: return "Slower shutter + higher ISO for dark scenes."
        case .vlog: return "Front camera, mirrored, smooth video."
        case .macro: return "Close-up focus for small details."
        case .video: return "Best video quality your phone supports, up to 4K60."
        }
    }
}

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "apexcam.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let dataOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private(set) var currentDevice: AVCaptureDevice?
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    @Published var isConfigured = false
    @Published var isFront = false
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var trackingOn = false
    @Published var trackedRect: CGRect? = nil      // normalized to preview layer bounds
    @Published var focusReticle: CGPoint? = nil    // normalized to preview layer bounds
    @Published var histogram: [Double] = Array(repeating: 0, count: 16)
    @Published var levelDegrees: Double = 0
    @Published var batteryPercent: Int = -1
    @Published var statusMessage: String? = nil
    @Published var lastSavedTick = 0               // bump to refresh gallery
    @Published var supportsRAW = false
    @Published var isTorchOn = false

    var dualSave = true
    var batterySaver = false { didSet { applyBatterySaver() } }
    var useRAW = false
    private var recordTimer: Timer?
    private var lastHistogramTime = Date.distantPast
    private let motion = CMMotionManager()
    private var volumeObservation: NSKeyValueObservation?

    static func vaultURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let v = docs.appendingPathComponent("ApexCamVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        return v
    }

    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryPercent = UIDevice.current.batteryLevel < 0 ? -1 : Int(UIDevice.current.batteryLevel * 100)
        NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let l = UIDevice.current.batteryLevel
            self?.batteryPercent = l < 0 ? -1 : Int(l * 100)
        }
        startLevel()
        observeVolume()
    }

    // MARK: Permissions / setup
    func requestAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if !granted {
                DispatchQueue.main.async { self.statusMessage = "Camera permission is off. Turn it on in Settings > ApexCam Pro > Camera, then reopen the app." }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.configureSession() }
            }
        }
    }

    private func configureSession() {
        guard !isConfigured else { session.startRunning(); return }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.statusMessage = "No camera was found on this device." }
            return
        }
        if session.canAddInput(input) { session.addInput(input); videoInput = input; currentDevice = device }
        if let mic = AVCaptureDevice.default(for: .audio), let aIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(aIn) {
            session.addInput(aIn); audioInput = aIn
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue(label: "apexcam.meta"))
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
            }
        }
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        dataOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(dataOutput) {
            session.addOutput(dataOutput)
            dataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "apexcam.data"))
        }
        session.commitConfiguration()
        selectBestVideoFormat(fps: 30)
        applyStabilization("cinematic")
        let rawOK = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        DispatchQueue.main.async {
            self.supportsRAW = rawOK
            self.isConfigured = true
        }
        session.startRunning()
    }

    func startRunning() { sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stopRunning() { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    // MARK: Level (CoreMotion)
    private func startLevel() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let m else { return }
            let roll = atan2(m.gravity.y, m.gravity.x) + Double.pi / 2
            var deg = roll * 180 / Double.pi
            if deg > 90 { deg -= 180 }; if deg < -90 { deg += 180 }
            self?.levelDegrees = deg
        }
    }

    // MARK: Volume-button shutter (best effort)
    private func observeVolume() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setActive(true)
        var last = audio.outputVolume
        volumeObservation = audio.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, let v = change.newValue, v != last else { return }
            last = v
            DispatchQueue.main.async {
                if self.isRecording { self.stopRecording() } else { self.capturePhoto() }
            }
        }
    }

    // MARK: Camera flip / zoom / torch
    func flipCamera() {
        sessionQueue.async {
            let target: AVCaptureDevice.Position = self.isFront ? .back : .front
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target)
                    ?? AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            self.session.beginConfiguration()
            if let old = self.videoInput { self.session.removeInput(old) }
            if self.session.canAddInput(input) { self.session.addInput(input); self.videoInput = input; self.currentDevice = device }
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.isFront = (target == .front); self.trackedRect = nil; self.trackingOn = false }
            self.selectBestVideoFormat(fps: 30)
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard let device = currentDevice else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.ramp(toVideoZoomFactor: clamped, withRate: 12)
            device.unlockForConfiguration()
        }
    }

    func setTorch(_ on: Bool) {
        guard let device = currentDevice, device.hasTorch else {
            DispatchQueue.main.async { self.statusMessage = "This camera has no flash/torch." }
            return
        }
        sessionQueue.async {
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.isTorchOn = on }
        }
    }

    // MARK: Focus / tracking point
    func focusAndExpose(atLayerPoint point: CGPoint) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        focusDevicePoint(devicePoint)
        DispatchQueue.main.async {
            self.focusReticle = CGPoint(x: point.x / max(layer.bounds.width, 1), y: point.y / max(layer.bounds.height, 1))
        }
    }

    private func focusDevicePoint(_ p: CGPoint) {
        guard let device = currentDevice else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = p; device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = p; device.exposureMode = .autoExpose }
            device.unlockForConfiguration()
        }
    }

    func enableTapTracking(atLayerPoint point: CGPoint) {
        focusAndExpose(atLayerPoint: point)
        DispatchQueue.main.async { self.trackingOn = true; self.statusMessage = "Tracking ON — focus follows the subject." }
    }

    // MARK: Manual / Auto controls
    func applyAuto() {
        guard let device = currentDevice else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
        }
    }

    func applyManual(iso: Float, shutterDenominator: Float, wbKelvin: Float, evBias: Float, focusPosition: Float) {
        guard let device = currentDevice else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            let dur = CMTime(value: 1, timescale: CMTimeScale(max(shutterDenominator, 1)))
            let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(duration: dur, iso: clampedISO, completionHandler: nil)
            }
            let gains = device.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: wbKelvin, tint: 0))
            let clamped = AVCaptureDevice.WhiteBalanceGains(
                redGain: min(max(gains.redGain, 1), device.maxWhiteBalanceGain),
                greenGain: min(max(gains.greenGain, 1), device.maxWhiteBalanceGain),
                blueGain: min(max(gains.blueGain, 1), device.maxWhiteBalanceGain))
            if device.isWhiteBalanceModeSupported(.locked) { device.setWhiteBalanceModeLocked(with: clamped, completionHandler: nil) }
            device.setExposureTargetBias(evBias, completionHandler: nil)
            if device.isFocusModeSupported(.locked) { device.setFocusModeLocked(lensPosition: min(max(focusPosition, 0), 1), completionHandler: nil) }
            device.unlockForConfiguration()
        }
    }

    func applyPreset(_ preset: CameraPreset) {
        switch preset {
        case .auto: applyAuto()
        case .sports:
            // Fast shutter 1/1000, auto ISO/WB — freeze motion
            guard let device = currentDevice else { return }
            sessionQueue.async {
                try? device.lockForConfiguration()
                if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: CMTime(value: 1, timescale: 1000), iso: AVCaptureISOCurrent, completionHandler: nil)
                }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                device.unlockForConfiguration()
            }
            DispatchQueue.main.async { self.statusMessage = "Sports: fast shutter (1/1000) to freeze motion." }
        case .portrait: applyAuto(); DispatchQueue.main.async { self.trackingOn = true }
        case .night:
            guard let device = currentDevice else { return }
            sessionQueue.async {
                try? device.lockForConfiguration()
                if device.isExposureModeSupported(.custom) {
                    let iso = min(device.activeFormat.maxISO, 800)
                    device.setExposureModeCustom(duration: CMTime(value: 1, timescale: 30), iso: iso, completionHandler: nil)
                }
                device.unlockForConfiguration()
            }
        case .vlog:
            if !isFront { flipCamera() }
            applyStabilization("cinematicExtended")
        case .macro:
            guard let device = currentDevice else { return }
            sessionQueue.async {
                try? device.lockForConfiguration()
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                device.unlockForConfiguration()
            }
            setZoom(1.0)
        case .video:
            selectBestVideoFormat(fps: 60)
            applyStabilization("cinematicExtended")
        }
    }

    // MARK: Video format / stabilization
    func selectBestVideoFormat(fps: Double) {
        guard let device = currentDevice else { return }
        sessionQueue.async {
            var best: AVCaptureDevice.Format? = nil
            var bestWidth: Int32 = 0
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width <= 3840 else { continue }
                let supports = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps && $0.minFrameRate <= fps }
                if supports && dims.width > bestWidth { best = format; bestWidth = dims.width }
            }
            // Slow-mo fallback: if fps > 60 no 4K format matches, take any format that supports it
            if best == nil && fps > 60 {
                for format in device.formats {
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    if format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= fps }) && dims.width > bestWidth {
                        best = format; bestWidth = dims.width
                    }
                }
            }
            guard let format = best else { return }
            try? device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        }
    }

    func applyStabilization(_ mode: String) {
        guard let conn = movieOutput.connection(with: .video), conn.isVideoStabilizationSupported else { return }
        let m: AVCaptureVideoStabilizationMode
        switch mode {
        case "off": m = .off
        case "standard": m = .standard
        case "cinematicExtended": m = .cinematicExtended
        case "auto": m = .auto
        default: m = .cinematic
        }
        conn.preferredVideoStabilizationMode = m
        if let pc = photoOutput.connection(with: .video), pc.isVideoStabilizationSupported {
            pc.preferredVideoStabilizationMode = m == .cinematicExtended ? .cinematic : m
        }
    }

    private func applyBatterySaver() {
        // Throttles tool updates; preview stays live. (Full fps change is format-dependent and guarded out for recording safety.)
        motion.deviceMotionUpdateInterval = batterySaver ? 0.4 : 0.15
    }

    // MARK: Photo capture
    func capturePhoto() {
        sessionQueue.async {
            var settings: AVCapturePhotoSettings?
            if self.useRAW, let raw = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                let s = AVCapturePhotoSettings(rawPixelFormatType: raw, processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings = s
            }
            if settings == nil {
                if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                }
            }
            guard let s = settings else { return }
            s.flashMode = (self.currentDevice?.hasFlash == true) ? .auto : .off
            if let conn = self.photoOutput.connection(with: .video), conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            self.photoOutput.capturePhoto(with: s, delegate: self)
        }
    }

    // MARK: Video recording
    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            if let conn = self.movieOutput.connection(with: .video), conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ApexCam-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() { sessionQueue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } } }

    // MARK: Saving (Photos + optional Vault dual-save)
    fileprivate func savePhotoData(_ data: Data, isRAW: Bool) {
        let ext = isRAW ? "dng" : "jpg"
        let name = "ApexCam-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: tmp)
        if dualSave {
            try? FileManager.default.copyItem(at: tmp, to: CameraManager.vaultURL().appendingPathComponent(name))
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.statusMessage = "Photos permission is off — your shot is in the in-app Gallery (Vault) if Dual Save is on." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tmp)
            }) { ok, _ in
                DispatchQueue.main.async {
                    self.lastSavedTick += 1
                    self.statusMessage = ok ? "Saved ✓" : "Save to Photos failed — check the in-app Gallery."
                }
            }
        }
    }

    fileprivate func saveVideoFile(_ url: URL) {
        var vaultCopy: URL? = nil
        if dualSave {
            let dest = CameraManager.vaultURL().appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: dest)
            vaultCopy = dest
        }
        _ = vaultCopy
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.statusMessage = "Photos permission is off — video is in the in-app Gallery (Vault) if Dual Save is on."; self.lastSavedTick += 1 }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                DispatchQueue.main.async {
                    self.lastSavedTick += 1
                    self.statusMessage = ok ? "Video saved ✓" : "Video save failed — check the in-app Gallery."
                }
            }
        }
    }
}

// MARK: - Delegates
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let rawData = photo.fileDataRepresentation(), photo.isRawPhoto {
            savePhotoData(rawData, isRAW: true); return
        }
        if let data = photo.fileDataRepresentation() {
            savePhotoData(data, isRAW: false)
        } else {
            DispatchQueue.main.async { self.statusMessage = "That shot didn't save — try again." }
        }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.isRecording = true; self.recordingSeconds = 0
            self.recordTimer?.invalidate()
            self.recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recordingSeconds += 1 }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.isRecording = false; self.recordTimer?.invalidate() }
        if error == nil { saveVideoFile(outputFileURL) }
    }
}

extension CameraManager: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let layer = previewLayer,
              let face = metadataObjects.first(where: { $0.type == .face }),
              let transformed = layer.transformedMetadataObject(for: face) else {
            if trackingOn { DispatchQueue.main.async { self.trackedRect = nil } }
            return
        }
        let b = layer.bounds
        guard b.width > 0, b.height > 0 else { return }
        let r = transformed.bounds
        let normalized = CGRect(x: r.minX / b.width, y: r.minY / b.height, width: r.width / b.width, height: r.height / b.height)
        let centerLayer = CGPoint(x: r.midX, y: r.midY)
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: centerLayer)
        DispatchQueue.main.async {
            self.trackedRect = normalized
            if self.trackingOn { self.focusDevicePoint(devicePoint) }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastHistogramTime) > (batterySaver ? 0.6 : 0.25) else { return }
        lastHistogramTime = now
        guard let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buf, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(buf, 0), h = CVPixelBufferGetHeightOfPlane(buf, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        guard w > 0, h > 0 else { return }
        var bins = Array(repeating: 0.0, count: 16)
        var count = 0.0
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let v = ptr[y * stride + x]
                bins[Int(v) / 16] += 1; count += 1
                x += 24
            }
            y += 24
        }
        guard count > 0 else { return }
        let normalized = bins.map { $0 / count }
        DispatchQueue.main.async { self.histogram = normalized }
    }
}
