import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("apexOnboarded") private var onboarded = false
    @State private var preset: CameraPreset = .allDay
    @State private var lutPreviewOn = true   // v4: mirrors cam's persisted preview toggle at launch
    @State private var proMode = false
    @State private var isVideoMode = false
    @State private var showTools = false
    @State private var showGallery = false
    @State private var showHelp = false

    // Pro controls
    @State private var iso: Double = 100
    @State private var shutterDenom: Double = 125
    @State private var wb: Double = 5500
    @State private var ev: Double = 0
    @State private var focusPos: Double = 0.5
    @State private var zoomFactor: Double = 1

    // Tools
    @State private var showGrid = false
    @State private var showLevel = true
    @State private var showHistogram = false
    @State private var showZebra = false
    @State private var showPeaking = false
    @State private var dualSave = true
    @State private var useRAW = false
    @State private var rainMode = false
    @State private var batterySaver = false
    @State private var stabilization = "auto"
    @State private var fps: Double = 30
    @State private var countdown = 0
    @State private var countdownTimer: Timer? = nil
    @State private var prompterTimer: Timer? = nil

    // Magic Tools
    @State private var motionAuto = false
    @State private var smileAuto = false
    @State private var soundAuto = false
    @State private var coachOn = true
    @State private var prompterOn = false
    @State private var prompterText = "Hey everyone! Welcome back to my video. Today we're checking out something awesome — let's get into it!"
    @State private var prompterSpeed: Double = 1
    @State private var prompterOffset: CGFloat = 260
    @State private var timelapseOn = false
    @State private var timelapseInterval: Double = 2
    @State private var timelapseFrames = 0
    @State private var tlTimer: Timer? = nil
    @State private var stopMotionOn = false
    @State private var onionImage: UIImage? = nil
    @State private var locationStampOn = false

    private var big: CGFloat { rainMode ? 1.35 : 1.0 }

    var body: some View {
        Group {
            if !onboarded {
                OnboardingView { onboarded = true }
            } else {
                cameraScreen
            }
        }
        .onAppear {
            cam.dualSave = dualSave; cam.useRAW = useRAW
            lutPreviewOn = cam.lutPreviewEnabled   // v4: restore persisted preview toggle
            // v2 (a): start the camera ONLY after onboarding is finished, and let
            // CameraManager's configure-once guard own starting the session.
            if onboarded { cam.requestAndConfigure() }
            cam.setSampleBufferToolsEnabled(showHistogram || motionAuto || smileAuto)
            cam.setHistogramVisible(showHistogram)
        }
        .onChange(of: onboarded) { _, done in
            if done { cam.requestAndConfigure() }
        }
        .onChange(of: showHistogram) { _, v in
            cam.setHistogramVisible(v)
            cam.setSampleBufferToolsEnabled(v || motionAuto || smileAuto)
        }
        .onChange(of: motionAuto) { _, v in cam.setSampleBufferToolsEnabled(showHistogram || v || smileAuto) }
        .onChange(of: smileAuto) { _, v in cam.setSampleBufferToolsEnabled(showHistogram || motionAuto || v) }
        .onChange(of: isVideoMode) { _, video in
            // Entering video picks a 16:9 format; leaving it restores full photo quality.
            if video { if preset != .video { cam.selectBestVideoFormat(fps: fps) } } else { cam.usePhotoMode() }
            // v4: LUTs are a PHOTOS feature — suspend the graded preview in video.
            cam.setLUTPreviewSuspended(video)
        }
        .onChange(of: prompterOn) { _, on in
            if !on { prompterTimer?.invalidate(); prompterTimer = nil }
        }
        // v3 (9): lifecycle is driven by scenePhase, NOT the root view's
        // onDisappear — sheets and onboarding swaps made onDisappear stop the
        // camera at the wrong times. Background/inactive stops; active resumes.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: cam.resumeIfConfigured()
            case .background, .inactive: cam.stopRunning()
            @unknown default: break
            }
        }
        .onDisappear {
            countdownTimer?.invalidate(); countdownTimer = nil
            prompterTimer?.invalidate(); prompterTimer = nil
        }
    }

    private var cameraScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(manager: cam)
                .ignoresSafeArea()
                // v3 (4): tap-only. The old DragGesture(minimumDistance: 0) sat on
                // the full-screen preview and competed with every button and the
                // preset ScrollView for touches.
                .gesture(
                    SpatialTapGesture().onEnded { v in
                        if cam.trackingOn { cam.enableTapTracking(atLayerPoint: v.location) }
                        else { cam.focusAndExpose(atLayerPoint: v.location) }
                    }
                )

            // v4: live graded LUT preview — its own leaf view reading only
            // cam.gradedPreviewImage (~10fps). Inserted under the overlays and
            // controls; hit-testing off, so taps still reach the preview below.
            if lutPreviewOn && !isVideoMode {
                GradedPreviewView(cam: cam)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // v3 (1): all high-frequency overlays live in leaf views now — their
            // re-renders no longer touch this parent body or the preview.
            TrackingOverlayView(cam: cam, showGrid: showGrid, showZebra: showZebra, showPeaking: showPeaking)
            if showHistogram {
                HistogramView(cam: cam)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 104).padding(.trailing, 12)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                topBar
                if let msg = cam.statusMessage {
                    Text(msg)
                        .font(.footnote.bold())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .onTapGesture { cam.statusMessage = nil }
                }
                if coachOn { CoachBarView(cam: cam, showGolden: preset == .auto) }
                Spacer()
                if prompterOn { teleprompter }
                if stopMotionOn, let img = onionImage {
                    Image(uiImage: img).resizable().scaledToFill().opacity(0.35).ignoresSafeArea()
                        .overlay(alignment: .top) { Text("STOP-MOTION — line up with the ghost of your last frame").font(.caption2.bold()).padding(6).background(.black.opacity(0.6), in: Capsule()).padding(.top, 120) }
                        .allowsHitTesting(false)
                }
                if proMode { proPanel }
                // v3 (7): the level indicator is a compact row IN the control
                // stack now — it used to float in the full-screen overlay at a
                // fixed offset and ended up half-buried under the preset row.
                if showLevel { LevelView(cam: cam) }
                // v4: the LUT bar — pick a look, import .cube files, strength.
                // A leaf view: it reads cam's LUT state so the parent body doesn't.
                if !isVideoMode { LUTBarView(cam: cam) }
                presetRow
                shutterRow
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            if countdown > 0 {
                Text("\(countdown)")
                    .font(.system(size: 110, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 12)
            }
        }
        .foregroundStyle(.white)
        .onChange(of: cam.lastSavedTick) { _, _ in
            if stopMotionOn, let newest = (try? FileManager.default.contentsOfDirectory(at: CameraManager.vaultURL(), includingPropertiesForKeys: nil))?
                .filter({ ["jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) })
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first,
               let img = UIImage(contentsOfFile: newest.path) { onionImage = img }
        }
        .sheet(isPresented: $showTools) { toolsSheet }
        .sheet(isPresented: $showGallery) { GalleryView(manager: cam) }
        .sheet(isPresented: $showHelp) { HelpView() }
    }

    // MARK: Top bar
    private var topBar: some View {
        HStack(spacing: 12) {
            Label(cam.batteryPercent >= 0 ? "\(cam.batteryPercent)%" : "--%", systemImage: "battery.75")
                .font(.subheadline.bold())
                .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.55), in: Capsule())
            // v3 (6): watchdog health pill — own leaf view, so its 1Hz updates
            // re-render only the pill. Tap it while STALLED to restart the camera.
            HealthPillView(cam: cam)
            if cam.trackingOn {
                Label("TRACKING ON", systemImage: "scope").font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 5).background(.yellow, in: Capsule()).foregroundStyle(.black)
            }
            RecordingPillView(cam: cam)
            Spacer()
            topButton(cam.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill") { cam.setTorch(!cam.isTorchOn) }
            topButton("arrow.triangle.2.circlepath.camera.fill") { cam.flipCamera() }
            topButton("slider.horizontal.3") { showTools = true }
            topButton("questionmark.circle.fill") { showHelp = true }
        }
    }

    private func topButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 19 * big, weight: .semibold))
                .frame(width: 46 * big, height: 46 * big)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Presets
    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(CameraPreset.allCases) { p in
                    Button {
                        let wasVideo = isVideoMode
                        preset = p
                        if p == .video || p == .vlog { isVideoMode = true }
                        else if isVideoMode { isVideoMode = false }  // triggers usePhotoMode via onChange
                        cam.applyPreset(p)
                        // v4: only restore photo mode when actually leaving video —
                        // calling usePhotoMode() unconditionally re-applied full
                        // Auto AFTER the preset and wiped the preset's exposure
                        // (it silently broke Sports in v3, and would break the
                        // All-Day default the same way).
                        if p != .video && p != .vlog && wasVideo { cam.usePhotoMode() }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: p.icon).font(.system(size: 20 * big))
                            Text(p.rawValue).font(.caption.bold())
                        }
                        .frame(width: 74 * big, height: 58 * big)
                        .background(preset == p ? Color.cyan : Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(preset == p ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Shutter row
    private var shutterRow: some View {
        HStack(alignment: .center) {
            Button { showGallery = true } label: {
                VStack(spacing: 2) { Image(systemName: "photo.on.rectangle.angled").font(.title3); Text("Gallery").font(.caption2.bold()) }
                    .frame(width: 62 * big, height: 52 * big).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)

            Spacer()

            Button {
                if isVideoMode { cam.toggleRecording() }
                else if preset == .vlog { startCountdownThenShoot() }
                else { cam.capturePhoto() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 5).frame(width: 84 * big, height: 84 * big)
                    if isVideoMode {
                        RoundedRectangle(cornerRadius: cam.isRecording ? 6 : 28)
                            .fill(.red).frame(width: cam.isRecording ? 34 : 62, height: cam.isRecording ? 34 : 62)
                    } else {
                        Circle().fill(.white).frame(width: 66 * big, height: 66 * big)
                    }
                }
            }.buttonStyle(.plain)
            .accessibilityLabel(isVideoMode ? "Record video" : "Take photo")

            Spacer()

            VStack(spacing: 8) {
                Button { isVideoMode.toggle() } label: {
                    Label(isVideoMode ? "Video" : "Photo", systemImage: isVideoMode ? "video.fill" : "camera.fill")
                        .font(.caption.bold())
                        .frame(width: 74 * big, height: 34 * big)
                        .background(isVideoMode ? Color.red : Color.black.opacity(0.55), in: Capsule())
                }.buttonStyle(.plain)
                Button { proMode.toggle(); if !proMode { cam.applyAuto() } } label: {
                    Text(proMode ? "PRO ✓" : "PRO")
                        .font(.caption.bold())
                        .frame(width: 74 * big, height: 34 * big)
                        .background(proMode ? Color.cyan : Color.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(proMode ? .black : .white)
                }.buttonStyle(.plain)
                Button { cam.trackingOn.toggle(); cam.statusMessage = cam.trackingOn ? "Tracking ON — tap a person, or faces auto-track." : "Tracking off." } label: {
                    Label("Track", systemImage: "scope").font(.caption.bold())
                        .frame(width: 74 * big, height: 34 * big)
                        .background(cam.trackingOn ? Color.yellow : Color.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(cam.trackingOn ? .black : .white)
                }.buttonStyle(.plain)
            }
        }
    }

    private func startCountdownThenShoot() {
        countdownTimer?.invalidate()
        countdown = 3
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            countdown -= 1
            if countdown <= 0 { t.invalidate(); countdownTimer = nil; cam.capturePhoto() }
        }
    }

    private var teleprompter: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.55)).frame(height: 190)
            Text(prompterText)
                .font(.title3.bold()).multilineTextAlignment(.center)
                .frame(width: 300).offset(y: prompterOffset)
                .clipped()
        }
        .frame(height: 190)
        .onAppear {
            prompterTimer?.invalidate()  // v2 (e): never stack a second scrolling timer
            prompterOffset = 130
            prompterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
                if !prompterOn { t.invalidate(); return }
                prompterOffset -= CGFloat(prompterSpeed) * 0.7
                if prompterOffset < -320 { prompterOffset = 130 }
            }
        }
        .onDisappear { prompterTimer?.invalidate(); prompterTimer = nil }
    }

    private func toggleTimelapse(_ on: Bool) {
        tlTimer?.invalidate(); tlTimer = nil
        if on {
            timelapseFrames = 0
            tlTimer = Timer.scheduledTimer(withTimeInterval: timelapseInterval, repeats: true) { _ in
                cam.capturePhoto(); timelapseFrames += 1
            }
            cam.statusMessage = "⏱️ Timelapse running — frames save to your Gallery/Vault. Turn it off in Tools."
        }
    }

    // MARK: Pro panel
    private var proPanel: some View {
        VStack(spacing: 8) {
            Text("PRO CONTROLS — drag, it applies right away").font(.caption.bold()).foregroundStyle(.cyan)
            proSlider("ISO (light sensitivity)", value: $iso, range: 50...1600, format: "%.0f")
            proSlider("Shutter (1/x sec — bigger = faster)", value: $shutterDenom, range: 4...2000, format: "1/%.0f")
            proSlider("White Balance (K)", value: $wb, range: 2500...7500, format: "%.0fK")
            proSlider("Brightness (EV)", value: $ev, range: -2...2, format: "%+.1f")
            proSlider("Focus (near ↔ far)", value: $focusPos, range: 0...1, format: "%.2f")
            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 2.0, 5.0], id: \.self) { z in
                    Button { zoomFactor = z; cam.setZoom(CGFloat(z)) } label: {
                        Text(z == 0.5 ? "0.5×" : "\(Int(z))×").font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 40 * big)
                            .background(zoomFactor == z ? Color.cyan : Color.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(zoomFactor == z ? .black : .white)
                    }.buttonStyle(.plain)
                }
                Button { cam.applyAuto(); proMode = false } label: {
                    Text("Back to Auto").font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 40 * big)
                        .background(Color.white, in: Capsule()).foregroundStyle(.black)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: iso) { _, _ in applyManual() }
        .onChange(of: shutterDenom) { _, _ in applyManual() }
        .onChange(of: wb) { _, _ in applyManual() }
        .onChange(of: ev) { _, _ in applyManual() }
        .onChange(of: focusPos) { _, _ in applyManual() }
    }

    private func proSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).frame(width: 150, alignment: .leading)
            Slider(value: value, in: range).tint(.cyan)
            Text(String(format: format, value.wrappedValue)).font(.caption.bold()).frame(width: 54, alignment: .trailing)
        }
    }

    private func applyManual() {
        cam.applyManual(iso: Float(iso), shutterDenominator: Float(shutterDenom), wbKelvin: Float(wb), evBias: Float(ev), focusPosition: Float(focusPos))
    }

    // MARK: Tools sheet
    private var toolsSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Camera health")
                        Spacer()
                        HealthPillView(cam: cam)
                    }
                    Button("Restart Camera") { cam.manualRestartCamera() }
                    Text("If the picture ever stalls, ApexCam restarts the camera by itself — the pill turns red (STALLED) first. You can also tap Restart Camera here, or tap the pill on the main screen while it's stalled.").font(.caption).foregroundStyle(.secondary)
                } header: { Text("🩺 Camera Health — new in v3") }
                Section("Easy wins") {
                    Toggle("Dual Save — backup copy in the app + Photos (like 2 memory cards)", isOn: $dualSave)
                        .onChange(of: dualSave) { _, v in cam.dualSave = v }
                    Toggle("Rain / Glove Mode — extra-big buttons", isOn: $rainMode)
                    Toggle("Battery Saver — slows the pro tools to save power", isOn: $batterySaver)
                        .onChange(of: batterySaver) { _, v in cam.batterySaver = v }
                    Toggle("Subject Tracking", isOn: Binding(get: { cam.trackingOn }, set: { cam.trackingOn = $0 }))
                }
                Section {
                    Toggle("🏃 Auto-Capture — camera shoots itself when the action happens", isOn: $motionAuto)
                        .onChange(of: motionAuto) { _, v in cam.motionAutoCapture = v }
                    Toggle("😊 Smile / Face Auto Shutter — face steady for 1 sec = photo", isOn: $smileAuto)
                        .onChange(of: smileAuto) { _, v in cam.smileAutoCapture = v }
                    Toggle("👏 Clap / Sound Shutter — loud sound takes the photo", isOn: $soundAuto)
                        .onChange(of: soundAuto) { _, v in cam.setSoundShutter(v) }
                    Toggle("💡 Coach Tips — live plain-English shooting tips", isOn: $coachOn)
                    Toggle("📍 Location Stamp — writes GPS into photo info (EXIF)", isOn: $locationStampOn)
                        .onChange(of: locationStampOn) { _, v in cam.setLocationStamp(v) }
                    Toggle("⏱️ Timelapse — auto photo every few seconds", isOn: $timelapseOn)
                        .onChange(of: timelapseOn) { _, v in toggleTimelapse(v) }
                    if timelapseOn {
                        Picker("Every", selection: $timelapseInterval) {
                            Text("0.5s").tag(0.5); Text("1s").tag(1.0); Text("2s").tag(2.0); Text("5s").tag(5.0)
                        }.onChange(of: timelapseInterval) { _, _ in if timelapseOn { toggleTimelapse(true) } }
                        Text("Frames so far: \(timelapseFrames) — find them in the Gallery.").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("🎬 Stop-Motion — ghost of your last frame to line up the next", isOn: $stopMotionOn)
                } header: { Text("✨ Magic Tools — Only in ApexCam") }
                Section {
                    Toggle("Show teleprompter over the camera (great for Vlog)", isOn: $prompterOn)
                    TextEditor(text: $prompterText).frame(height: 90)
                    HStack { Text("Scroll speed").font(.caption); Slider(value: $prompterSpeed, in: 0.3...3) }
                    Text("Tip: use the Vlog preset (front camera), turn this on, and read while you record.").font(.caption).foregroundStyle(.secondary)
                } header: { Text("📜 Vlog Teleprompter") }
                Section {
                    LUTToolsSection(cam: cam) { on in lutPreviewOn = on }
                } header: { Text("🎨 LUT Looks — Photos (new in v4)") }
                Section("Look of the shot") {
                    Toggle("Grid (rule of thirds)", isOn: $showGrid)
                    Toggle("Level (keep it straight)", isOn: $showLevel)
                    Toggle("Histogram (brightness graph)", isOn: $showHistogram)
                    Toggle("Zebra warning (too-bright alert)", isOn: $showZebra)
                    Toggle("Focus Peaking indicator", isOn: $showPeaking)
                    Toggle("RAW photo (huge file, best for editing)", isOn: $useRAW)
                        .disabled(!cam.supportsRAW)
                        .onChange(of: useRAW) { _, v in cam.useRAW = v }
                    if !cam.supportsRAW { Text("RAW isn't available on this camera, so it's off.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Video") {
                    Picker("Smoothness (stabilization)", selection: $stabilization) {
                        Text("Off").tag("off"); Text("Standard").tag("standard")
                        Text("Cinematic").tag("cinematic"); Text("Cinematic Extended (smoothest)").tag("cinematicExtended")
                        Text("Auto").tag("auto")
                    }.onChange(of: stabilization) { _, v in cam.applyStabilization(v) }
                    Picker("Frames per second", selection: $fps) {
                        Text("24 — movie look").tag(24.0); Text("30 — normal").tag(30.0)
                        Text("60 — smooth").tag(60.0); Text("120 — slow-mo").tag(120.0); Text("240 — super slow-mo").tag(240.0)
                    }.onChange(of: fps) { _, v in cam.selectBestVideoFormat(fps: v) }
                    Text("ApexCam always picks the biggest size your phone supports for that speed — up to 4K. Slow-mo speeds use a smaller size, that's normal.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text(preset.blurb).font(.callout)
                } header: { Text("About “\(preset.rawValue)”") }
            }
            .navigationTitle("Tools & Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showTools = false } } }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Leaf views (v3 (1))
// Each of these is its own View struct with its own @ObservedObject cam, so a
// publish of levelDegrees / histogram / trackedRect / healthText / recording
// state re-renders ONLY that small subtree — never the parent camera screen
// and never the UIViewRepresentable preview. The parent ContentView body reads
// none of those high-frequency values (verified by grep).

// MARK: - LUT leaf views (v4)
// GradedPreviewView is the ONLY view that reads cam.gradedPreviewImage (the
// ~10fps graded frame). LUTBarView owns the LUT picker/import/strength UI and
// reads cam's LUT state, which changes only on user action. Neither touches
// the parent ContentView body.

struct GradedPreviewView: View {
    @ObservedObject var cam: CameraManager
    var body: some View {
        GeometryReader { geo in
            if let img = cam.gradedPreviewImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        Text("LUT PREVIEW")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.top, 54).padding(.leading, 10)
                    }
            }
        }
    }
}

struct LUTBarView: View {
    @ObservedObject var cam: CameraManager
    @State private var showImporter = false
    @State private var draftStrength: Double? = nil   // non-nil while the slider is being dragged
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { expanded.toggle() } label: {
                    Label("LUT", systemImage: "camera.filters")
                        .font(.caption.bold())
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(Color.orange, in: Capsule())
                        .foregroundStyle(.black)
                }.buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(cam.lutAvailableNames, id: \.self) { name in
                            Button { cam.selectLUT(name) } label: {
                                Text(name)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(cam.lutSelectedName == name ? Color.orange : Color.black.opacity(0.55), in: Capsule())
                                    .foregroundStyle(cam.lutSelectedName == name ? .black : .white)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Button { showImporter = true } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.caption.bold())
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule())
                }.buttonStyle(.plain)
            }
            if expanded && cam.lutSelectedName != "None" {
                HStack(spacing: 10) {
                    Text("Strength").font(.caption2.bold())
                    Slider(value: Binding(
                        get: { draftStrength ?? cam.lutStrength * 100 },
                        set: { draftStrength = $0 }
                    ), in: 0...100, onEditingChanged: { editing in
                        // Commit (and rebuild the cube) once, when the drag ends.
                        if !editing, let d = draftStrength { cam.setLUTStrength(d / 100); draftStrength = nil }
                    })
                    .tint(.orange)
                    Text("\(Int(draftStrength ?? cam.lutStrength * 100))%")
                        .font(.caption.bold()).frame(width: 38, alignment: .trailing)
                    Toggle(isOn: Binding(get: { cam.lutApplyEnabled }, set: { cam.setLUTApply($0) })) {
                        Text("Bake in").font(.caption2.bold())
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { cam.importLUT(from: url) }
            }
        }
    }
}

/// Tools-sheet LUT section: preview toggle + honest Photos-only labelling.
struct LUTToolsSection: View {
    @ObservedObject var cam: CameraManager
    var onPreviewToggle: (Bool) -> Void
    var body: some View {
        Toggle("Live LUT preview — see the look on screen while you shoot", isOn: Binding(
            get: { cam.lutPreviewEnabled },
            set: { cam.setLUTPreview($0); onPreviewToggle($0) }
        ))
        Toggle("Apply LUT to saved photo — the graded photo is what saves (like Blackmagic's Record LUT to Clip)", isOn: Binding(
            get: { cam.lutApplyEnabled },
            set: { cam.setLUTApply($0) }
        ))
        Text("LUTs apply to PHOTOS. Video records without a LUT — ApexCam doesn't fake it. Import your own .cube files (17/32/33/64-point) from the LUT bar on the main screen; they stay in the app for next time. Built-in looks are generated by the app itself.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct HealthPillView: View {
    @ObservedObject var cam: CameraManager
    private var color: Color {
        if cam.healthText.contains("LIVE") { return .green }
        if cam.healthText.contains("STALLED") { return .red }
        return .yellow
    }
    var body: some View {
        Button {
            if cam.healthText.contains("STALLED") { cam.manualRestartCamera() }
        } label: {
            Text(cam.healthText)
                .font(.caption.bold())
                .foregroundStyle(color)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RecordingPillView: View {
    @ObservedObject var cam: CameraManager
    var body: some View {
        if cam.isRecording {
            Label(String(format: "%02d:%02d", cam.recordingSeconds / 60, cam.recordingSeconds % 60), systemImage: "record.circle.fill")
                .font(.subheadline.bold()).foregroundStyle(.red)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.55), in: Capsule())
        }
    }
}

struct LevelView: View {
    @ObservedObject var cam: CameraManager
    var body: some View {
        let level = abs(cam.levelDegrees) < 1.5
        HStack(spacing: 8) {
            Spacer()
            ZStack {
                Capsule().fill(.white.opacity(0.25)).frame(width: 110, height: 4)
                Capsule().fill(level ? .green : .yellow).frame(width: 38, height: 4)
                    .offset(x: CGFloat(max(min(cam.levelDegrees, 30), -30)) * 1.2)
            }
            Text(level ? "Level ✓" : String(format: "Tilt %.0f°", cam.levelDegrees))
                .font(.caption2.bold())
            Spacer()
        }
        .padding(.vertical, 3)
        .allowsHitTesting(false)
    }
}

struct HistogramView: View {
    @ObservedObject var cam: CameraManager
    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(0..<16, id: \.self) { i in
                Rectangle().fill(.white.opacity(0.85)).frame(width: 7, height: CGFloat(cam.histogram[i]) * 900 + 2)
            }
        }
        .padding(6).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TrackingOverlayView: View {
    @ObservedObject var cam: CameraManager
    var showGrid: Bool
    var showZebra: Bool
    var showPeaking: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if showGrid {
                    GridOverlay().stroke(.white.opacity(0.35), lineWidth: 1)
                }
                if showZebra {
                    // Simple highlight-warning indicator chip; full per-pixel zebra
                    // needs a Metal shader (later). Honestly labeled in the UI.
                    VStack { HStack { Label("Zebra ON — watch bright areas", systemImage: "stripe").font(.caption2.bold()).padding(6).background(.red.opacity(0.7), in: Capsule()); Spacer() }; Spacer() }
                        .padding(.top, 64).padding(.leading, 10)
                }
                if showPeaking {
                    RoundedRectangle(cornerRadius: 6).stroke(.green.opacity(0.55), lineWidth: 2)
                        .overlay(alignment: .topTrailing) { Text("PEAKING ON").font(.caption2.bold()).padding(6) }
                }
                if let r = cam.trackedRect {
                    let rect = CGRect(x: r.minX * geo.size.width, y: r.minY * geo.size.height, width: r.width * geo.size.width, height: r.height * geo.size.height)
                    RoundedRectangle(cornerRadius: 8).stroke(.yellow, lineWidth: 3).frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    Text("TRACKING").font(.caption2.bold()).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.yellow, in: Capsule())
                        .position(x: rect.midX, y: max(rect.minY - 14, 10))
                }
                if let f = cam.focusReticle {
                    RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: 1.5).frame(width: 56, height: 56)
                        .position(x: f.x * geo.size.width, y: f.y * geo.size.height)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct CoachBarView: View {
    @ObservedObject var cam: CameraManager
    var showGolden: Bool
    private var brightness: Double { cam.histogram.enumerated().reduce(0) { $0 + $1.element * Double($1.offset * 16 + 8) } / 255.0 }
    private var coachTip: String {
        if brightness > 0 && brightness < 0.22 { return "💡 Coach: Too dark — tap the torch (flashlight button) or use the Night preset." }
        if cam.trackedRect != nil { return "💡 Coach: Face found — you're in focus. Shoot!" }
        if abs(cam.levelDegrees) > 4 { return "💡 Coach: Level your shot — tilt the phone until the line turns green." }
        if brightness > 0.85 { return "💡 Coach: Very bright — try EV −1 in PRO so highlights don't blow out." }
        return "💡 Coach: Looks good — steady hands, shoot away."
    }
    private var goldenBadge: String {
        // Approx sunset from day-of-year + coarse latitude (solar math, no exact location needed)
        let cal = Calendar.current
        let n = Double(cal.ordinality(of: .day, in: .year, for: Date()) ?? 172)
        let lat = (cam.latitude ?? 39.0) * Double.pi / 180
        let decl = -23.44 * Double.pi / 180 * cos(2 * Double.pi / 365 * (n + 10))
        let cosH = min(max((cos(90.833 * Double.pi / 180) - sin(lat) * sin(decl)) / (cos(lat) * cos(decl)), -1), 1)
        let sunset = 12 + acos(cosH) * 180 / Double.pi / 15  // local solar time, approx
        let golden = sunset - 1
        let h = Int(golden), m = Int((golden - Double(h)) * 60)
        let hour12 = h > 12 ? h - 12 : max(h, 1)
        return "🌅 Golden hour ~\(hour12):\(String(format: "%02d", m)) PM (approx)"
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(coachTip).font(.caption.bold())
            Spacer()
            if showGolden { Text(goldenBadge).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 4).background(Color.orange.opacity(0.85), in: Capsule()) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.black.opacity(0.6), in: Capsule())
    }
}

struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return p
    }
}
