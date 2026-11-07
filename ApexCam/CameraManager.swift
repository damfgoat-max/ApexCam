import Foundation
import AVFoundation
import Photos
import UIKit
import CoreMotion
import CoreLocation
import ImageIO

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
    @Published var needsSampleBuffer = false   // true while histogram/motion/smile tools need the data output
    @Published var healthText = "● STARTING"   // v3 watchdog: ● LIVE / ● STARTING / ● STALLED (leaf-view only)
    private var isConfiguring = false          // configure-once guard (a)
    private var dataOutputAttached = false     // lazy data output state (c)
    private var histogramVisible = false       // publish histogram only when its tool is on screen (b)
    private var requestedVideoFPS: Double? = nil  // non-nil only while a video format is active (f)
    private var lastPublishedLevel: Double = 0
    private var lastLevelPublishTime = Date.distantPast
    private let motionQueue = OperationQueue()
    // v3 watchdog / heartbeat state
    private var lastMetadataHeartbeat = Date.distantPast   // written on the metadata delegate queue
    private var healthTimer: Timer? = nil
    private var sessionStartedAt = Date.distantPast        // for the volume-KVO launch guard
    private var restartGraceUntil = Date.distantPast
    private var restartedOnceThisStall = false
    private var rebuiltThisStall = false
    private(set) var captureInFlight = false               // volume-KVO guard during captures
    // v3 metadata-delegate dedup state (delegate queue only)
    private var metaLastFacePresent = false
    private var metaLastPostedRect: CGRect? = nil
    private var metaLastRectPostTime = Date.distantPast
    @Published var isTorchOn = false
    @Published var latitude: Double? = nil

    // Magic Tools
    var motionAutoCapture = false
    var smileAutoCapture = false
    var locationStamp = false
    private var lastAvgLuma: Double = -1
    private var lastAutoShot = Date.distantPast
    private var faceFirstSeen: Date? = nil
    private var audioRecorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private let locationManager = CLLocationManager()
    private(set) var lastLocation: CLLocation? = nil

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
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        // v3: session health observers — a runtime error or a finished interruption
        // runs the same self-restart path as the watchdog.
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.handleSessionFailure("Camera hit an error and restarted itself.")
        }
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.restartGraceUntil = Date().addingTimeInterval(6)
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.handleSessionFailure("Camera was interrupted and restarted itself.")
        }
        // v3 (8): when the subject area changes (device moved a lot), re-center AF/AE.
        nc.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let dev = note.object as? AVCaptureDevice, dev === self.currentDevice else { return }
            self.sessionQueue.async { self.applyCenterFocusExposureOnSessionQueue() }
        }
    }

    // Shared failure path for runtime errors / interruptions: simple restart first.
    private func handleSessionFailure(_ message: String) {
        DispatchQueue.main.async { self.statusMessage = message }
        restartSession(rebuild: false)
    }

    // MARK: Location stamp (EXIF GPS)
    func setLocationStamp(_ on: Bool) {
        locationStamp = on
        if on {
            locationManager.requestWhenInUseAuthorization()
            locationManager.requestLocation()
        }
    }

    // MARK: Clap / sound shutter (mic metering, best effort)
    func setSoundShutter(_ on: Bool) {
        if on {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("apex-meter.caf")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1]
            do {
                audioRecorder = try AVAudioRecorder(url: url, settings: settings)
                audioRecorder?.isMeteringEnabled = true
                audioRecorder?.record()
                meterTimer?.invalidate()
                meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let self, let r = self.audioRecorder, !self.isRecording else { return }
                    r.updateMeters()
                    if r.averagePower(forChannel: 0) > -10, Date().timeIntervalSince(self.lastAutoShot) > 3 {
                        self.lastAutoShot = Date()
                        DispatchQueue.main.async { self.statusMessage = "👏 Clap heard — shot taken!" }
                        self.capturePhoto()
                    }
                }
            } catch {
                DispatchQueue.main.async { self.statusMessage = "Sound shutter couldn't start the mic meter on this phone." }
            }
        } else {
            meterTimer?.invalidate(); audioRecorder?.stop(); audioRecorder = nil
        }
    }

    private func embedGPS(into data: Data) -> Data {
        guard locationStamp, let loc = lastLocation,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return data }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return data }
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        let gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(lat),
            kCGImagePropertyGPSLatitudeRef as String: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(lon),
            kCGImagePropertyGPSLongitudeRef as String: lon >= 0 ? "E" : "W",
        ]
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGPSDictionary as String: gps] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (out as Data) : data
    }


    // MARK: Permissions / setup
    func requestAndConfigure() {
        // v2 (a): no-op if already configured or a configure is already in flight.
        guard !isConfigured, !isConfiguring else { return }
        isConfiguring = true
        startWatchdogIfNeeded()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if !granted {
                self.isConfiguring = false
                DispatchQueue.main.async { self.statusMessage = "Camera permission is off. Turn it on in Settings > ApexCam Pro > Camera, then reopen the app." }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.configureSession() }
            }
        }
    }

    private func configureSession() {
        // Runs on sessionQueue. Configures exactly once; starts the session exactly once.
        guard !isConfigured else { if !session.isRunning { session.startRunning() }; return }
        session.beginConfiguration()
        // v2 (f): photo preset at launch — AVFoundation picks its optimal high-quality
        // format. No custom activeFormat is forced until the user shoots video / picks fps.
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            isConfiguring = false
            DispatchQueue.main.async { self.statusMessage = "No camera was found on this device." }
            return
        }
        if session.canAddInput(input) { session.addInput(input); videoInput = input; currentDevice = device }
        if let mic = AVCaptureDevice.default(for: .audio), let aIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(aIn) {
            session.addInput(aIn); audioInput = aIn
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // v2 (h): best capture quality + largest photo dimensions the device offers.
            photoOutput.maxPhotoQualityPrioritization = .quality
            updateMaxPhotoDimensions(for: device)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue(label: "apexcam.meta"))
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
            }
        }
        // v2 (c): the video data output is NOT added here — it is attached lazily by
        // setSampleBufferToolsEnabled when histogram / motion-auto / smile tools turn on.
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        dataOutput.alwaysDiscardsLateVideoFrames = true
        session.commitConfiguration()
        // v2 (g): gentle stabilization on the MOVIE connection only; nothing cinematic
        // is applied to the photo connection (that crops the sensor = softer/grainier).
        applyStabilization("auto")
        // v2 (h): explicitly put the device in full system-auto (focus/exposure/WB) at
        // launch so no custom exposure state leaks into the first shot.
        applyAutoOnSessionQueue()
        // v3 (8): center AF/AE + smooth AF + subject-area monitoring, so the first
        // frame isn't the dark/defocused one from the user's screenshot.
        applyCenterFocusExposureOnSessionQueue()
        let rawOK = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        isConfiguring = false
        DispatchQueue.main.async {
            self.supportsRAW = rawOK
            self.isConfigured = true
        }
        restartGraceUntil = Date().addingTimeInterval(4)
        if !session.isRunning { session.startRunning(); sessionStartedAt = Date() }
    }

    // v3 (8): must be called on sessionQueue. Center focus/exposure with continuous
    // modes, smooth AF when the device offers it, and subject-area change monitoring
    // (the observer registered in init re-runs this when the subject area changes).
    private func applyCenterFocusExposureOnSessionQueue() {
        guard let device = currentDevice else { return }
        try? device.lockForConfiguration()
        let center = CGPoint(x: 0.5, y: 0.5)
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = center
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = center
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
        device.isSubjectAreaChangeMonitoringEnabled = true
        device.unlockForConfiguration()
    }

    // Largest maxPhotoDimensions the active format supports (guarded).
    private func updateMaxPhotoDimensions(for device: AVCaptureDevice) {
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        if let largest = dims.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
    }

    // MARK: Lazy sample-buffer tools (c)
    func setHistogramVisible(_ visible: Bool) { histogramVisible = visible }

    func setSampleBufferToolsEnabled(_ enabled: Bool) {
        if needsSampleBuffer != enabled {
            DispatchQueue.main.async { self.needsSampleBuffer = enabled }
        }
        sessionQueue.async {
            if enabled, !self.dataOutputAttached {
                self.session.beginConfiguration()
                if self.session.canAddOutput(self.dataOutput) {
                    self.dataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "apexcam.data"))
                    self.session.addOutput(self.dataOutput)
                    self.dataOutputAttached = true
                }
                self.session.commitConfiguration()
            } else if !enabled, self.dataOutputAttached {
                self.session.beginConfiguration()
                self.session.removeOutput(self.dataOutput)
                self.dataOutputAttached = false
                self.lastAvgLuma = -1
                self.session.commitConfiguration()
            }
        }
    }

    func startRunning() {
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning(); self.sessionStartedAt = Date() }
        }
    }
    func stopRunning() { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    // v3 (9): lifecycle resume — scenePhase .active restarts a configured session.
    func resumeIfConfigured() {
        guard isConfigured else { return }
        startRunning()
    }

    // v3 (6): manual restart from the health pill / Tools sheet.
    func manualRestartCamera() {
        restartedOnceThisStall = false
        rebuiltThisStall = false
        DispatchQueue.main.async { self.statusMessage = "Restarting the camera…" }
        restartSession(rebuild: false)
    }

    // v3 (6): restart path. Simple: stop/start. Rebuild: tear the session down to
    // empty and re-run the whole configure (the preview layer keeps this same
    // session object, so the picture comes back on its own).
    func restartSession(rebuild: Bool) {
        restartGraceUntil = Date().addingTimeInterval(5)
        DispatchQueue.main.async { if self.isConfigured { self.healthText = "● STARTING" } }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            if rebuild {
                self.session.beginConfiguration()
                for input in self.session.inputs { self.session.removeInput(input) }
                for output in self.session.outputs { self.session.removeOutput(output) }
                self.session.commitConfiguration()
                self.videoInput = nil; self.audioInput = nil
                self.dataOutputAttached = false
                self.isConfiguring = false
                DispatchQueue.main.async { self.isConfigured = false }
                // requestAndConfigure flips isConfiguring itself; do it after the
                // published flag clears so its guard passes.
                DispatchQueue.main.async { self.requestAndConfigure() }
            } else {
                self.session.startRunning()
                self.sessionStartedAt = Date()
            }
        }
    }

    // v3 (6): 1-second watchdog. The metadata delegate stamps lastMetadataHeartbeat
    // on its own queue; if callbacks stop while configured, the session is stalled:
    // restart once, then escalate to a full rebuild if it stalls again.
    private func startWatchdogIfNeeded() {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            if self.isConfiguring || !self.isConfigured {
                if self.healthText != "● STARTING" { self.healthText = "● STARTING" }
                return
            }
            if now < self.restartGraceUntil {
                if self.healthText != "● STARTING" { self.healthText = "● STARTING" }
                return
            }
            let age = now.timeIntervalSince(self.lastMetadataHeartbeat)
            if age < 1.5 {
                if self.healthText != "● LIVE" { self.healthText = "● LIVE" }
                self.restartedOnceThisStall = false
                self.rebuiltThisStall = false
            } else if age > 2.5 {
                if self.healthText != "● STALLED" { self.healthText = "● STALLED" }
                if !self.restartedOnceThisStall {
                    self.restartedOnceThisStall = true
                    self.statusMessage = "Camera stalled — restarting it…"
                    self.restartSession(rebuild: false)
                } else if !self.rebuiltThisStall {
                    self.rebuiltThisStall = true
                    self.statusMessage = "Camera still stalled — rebuilding it…"
                    self.restartSession(rebuild: true)
                }
            }
        }
    }

    // MARK: Level (CoreMotion)
    private func startLevel() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.25
        motionQueue.name = "apexcam.motion"
        motionQueue.maxConcurrentOperationCount = 1
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] m, _ in
            guard let self, let m else { return }
            let roll = atan2(m.gravity.y, m.gravity.x) + Double.pi / 2
            var deg = roll * 180 / Double.pi
            if deg > 90 { deg -= 180 }; if deg < -90 { deg += 180 }
            let rounded = deg.rounded()
            // v3 (2): publish at most ~4x/sec and only on a >= 2 degree change;
            // the level now lives in a leaf view, but keep the publish rate low too.
            let now = Date()
            guard abs(rounded - self.lastPublishedLevel) >= 2,
                  now.timeIntervalSince(self.lastLevelPublishTime) >= 0.25 else { return }
            self.lastPublishedLevel = rounded
            self.lastLevelPublishTime = now
            DispatchQueue.main.async { self.levelDegrees = rounded }
        }
    }

    // MARK: Volume-button shutter (best effort)
    private func observeVolume() {
        // v2 (d): do NOT setActive(true) here — activating our own audio session at
        // launch can fight the capture session. KVO on outputVolume works without it.
        let audio = AVAudioSession.sharedInstance()
        var last = audio.outputVolume
        volumeObservation = audio.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, let v = change.newValue, v != last else { return }
            last = v
            // v3 (5): the capture session itself moves outputVolume when it starts —
            // ignore changes in the first 3s after start and during a capture, or
            // the app takes (or interferes with) photos all by itself.
            guard Date().timeIntervalSince(self.sessionStartedAt) > 3, !self.captureInFlight else { return }
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
            self.updateMaxPhotoDimensions(for: device)
            DispatchQueue.main.async {
                self.isFront = (target == .front); self.trackedRect = nil; self.trackingOn = false
                self.metaLastFacePresent = false; self.metaLastPostedRect = nil  // v3: re-post fresh after a flip
            }
            // Photo mode keeps the system format after a flip; only re-apply a custom
            // format if the user is actually in a video/fps selection right now.
            if let fps = self.requestedVideoFPS { self.selectBestVideoFormat(fps: fps) }
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
        sessionQueue.async { self.applyAutoOnSessionQueue() }
    }

    // Must be called on sessionQueue (or during configure). Full system-auto: the
    // phone's best focus/exposure/white-balance; Auto never hand-raises ISO (i).
    private func applyAutoOnSessionQueue() {
        guard let device = currentDevice else { return }
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        device.unlockForConfiguration()
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
                    device.setExposureModeCustom(duration: CMTime(value: 1, timescale: 1000), iso: device.iso, completionHandler: nil)
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
        requestedVideoFPS = fps
        guard let device = currentDevice else { return }
        sessionQueue.async {
            // Score formats: 3840x2160 first, then 1920x1080, then any other 16:9,
            // then anything else by width. 4:3 full-sensor formats are avoided — the
            // full-screen portrait preview would crop them heavily (= soft/grainy).
            func score(_ format: AVCaptureDevice.Format) -> (Int, Int32) {
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let stab = format.isVideoStabilizationSupported ? 1 : 0  // tiebreak: cinematic-capable
                if d.width == 3840 && d.height == 2160 { return (400 + stab, d.width) }
                if d.width == 1920 && d.height == 1080 { return (300 + stab, d.width) }
                if d.height > 0, abs(Double(d.width) / Double(d.height) - 16.0 / 9.0) < 0.01 { return (200 + stab, d.width) }
                return (stab, d.width)
            }
            let supportsFPS = { (format: AVCaptureDevice.Format) in
                format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps && $0.minFrameRate <= fps }
            }
            var candidates = device.formats.filter(supportsFPS)
            if candidates.isEmpty && fps > 60 {
                // Slow-mo fallback: any format that can reach the requested rate.
                candidates = device.formats.filter { f in f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps } }
            }
            guard let format = candidates.max(by: { score($0) < score($1) }) else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority  // required to set a custom activeFormat
            try? device.lockForConfiguration()
            device.activeFormat = format
            if fps == 24 || fps == 30 {
                // v2 (f): don't lock frame duration at normal rates — locking fights
                // the phone's low-light exposure and adds noise/grain.
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
            } else {
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
            self.session.commitConfiguration()
        }
    }

    // Back to still-photo shooting: restore the .photo preset and clear any
    // frame-rate locks so the preview/capture return to full system quality (f).
    func usePhotoMode() {
        requestedVideoFPS = nil
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if let device = self.currentDevice {
                try? device.lockForConfiguration()
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
                device.unlockForConfiguration()
                self.updateMaxPhotoDimensions(for: device)
            }
            self.session.commitConfiguration()
            self.applyAutoOnSessionQueue()
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
        // v2 (g): the PHOTO connection is deliberately left alone — stabilizing it
        // crops the sensor and makes preview/photos softer and grainier.
    }

    private func applyBatterySaver() {
        // Throttles tool updates; preview stays live. (Full fps change is format-dependent and guarded out for recording safety.)
        motion.deviceMotionUpdateInterval = batterySaver ? 0.5 : 0.25
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
            s.photoQualityPrioritization = .quality  // v2 (h)
            s.flashMode = (self.currentDevice?.hasFlash == true) ? .auto : .off
            if let conn = self.photoOutput.connection(with: .video), conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            self.captureInFlight = true   // v3 (5): cleared in the photo delegate, incl. errors
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
    fileprivate func savePhotoData(_ dataIn: Data, isRAW: Bool) {
        let data = isRAW ? dataIn : embedGPS(into: dataIn)
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
    // v3 (5): always the last callback for a capture, success or error — the
    // volume-shutter guard flag is cleared here so it can never get stuck on.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        captureInFlight = false
        if error != nil {
            DispatchQueue.main.async { self.statusMessage = "That shot didn't work — try again." }
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
    // v3 (3)+(6): runs on the apexcam.meta queue. Every callback stamps the
    // watchdog heartbeat. Main-queue posts happen ONLY when something actually
    // changed, throttled to ~15fps — a no-face/no-change callback touches no
    // queue but this one.
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        lastMetadataHeartbeat = Date()
        let face = metadataObjects.first(where: { $0.type == .face })
        guard let face, let layer = previewLayer,
              let transformed = layer.transformedMetadataObject(for: face) else {
            // No face: clear local state here; post trackedRect=nil to main ONCE,
            // only if a face was previously present.
            faceFirstSeen = nil
            if metaLastFacePresent {
                metaLastFacePresent = false
                metaLastPostedRect = nil
                DispatchQueue.main.async { self.trackedRect = nil }
            }
            return
        }
        let b = layer.bounds
        guard b.width > 0, b.height > 0 else { return }
        let r = transformed.bounds
        let normalized = CGRect(x: r.minX / b.width, y: r.minY / b.height, width: r.width / b.width, height: r.height / b.height)

        // Smile auto-shutter: entirely on this queue. capturePhoto() hops to
        // sessionQueue itself, so no main bounce is needed except the message.
        if smileAutoCapture {
            if faceFirstSeen == nil { faceFirstSeen = Date() }
            if let since = faceFirstSeen, Date().timeIntervalSince(since) > 1.0,
               Date().timeIntervalSince(lastAutoShot) > 3.5, !isRecording {
                lastAutoShot = Date(); faceFirstSeen = nil
                DispatchQueue.main.async { self.statusMessage = "😊 Face steady — auto shot!" }
                capturePhoto()
            }
        } else {
            faceFirstSeen = nil
        }

        // Tracking focus follows the face — focusDevicePoint hops to sessionQueue.
        if trackingOn {
            let centerLayer = CGPoint(x: r.midX, y: r.midY)
            focusDevicePoint(layer.captureDevicePointConverted(fromLayerPoint: centerLayer))
        }

        // Post the rect only on meaningful movement, at most ~15fps.
        let now = Date()
        let moved: Bool
        if let last = metaLastPostedRect {
            moved = abs(normalized.midX - last.midX) > 0.01 || abs(normalized.midY - last.midY) > 0.01
                || abs(normalized.width - last.width) > 0.01 || abs(normalized.height - last.height) > 0.01
        } else { moved = true }
        let firstAppearance = !metaLastFacePresent
        metaLastFacePresent = true
        guard (moved || firstAppearance), now.timeIntervalSince(metaLastRectPostTime) > 0.066 else { return }
        metaLastRectPostTime = now
        metaLastPostedRect = normalized
        DispatchQueue.main.async { self.trackedRect = normalized }
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
        let avg = bins.enumerated().reduce(0.0) { $0 + $1.element * Double($1.offset * 16 + 8) / max(count, 1) } / 255.0
        if motionAutoCapture, lastAvgLuma >= 0, abs(avg - lastAvgLuma) > 0.045, Date().timeIntervalSince(lastAutoShot) > 3.5, !isRecording {
            lastAutoShot = Date()
            DispatchQueue.main.async { self.statusMessage = "🏃 Motion seen — auto shot!" }
            capturePhoto()
        }
        lastAvgLuma = avg
        // v2 (b): publish the histogram only when its tool is actually on screen.
        if histogramVisible {
            let normalized = bins.map { $0 / count }
            DispatchQueue.main.async { self.histogram = normalized }
        }
    }
}


extension CameraManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
        if let c = locations.last?.coordinate { DispatchQueue.main.async { self.latitude = c.latitude } }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if locationStamp, manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
}
