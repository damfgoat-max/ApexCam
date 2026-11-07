import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @AppStorage("apexOnboarded") private var onboarded = false
    @State private var preset: CameraPreset = .auto
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
    @State private var stabilization = "cinematicExtended"
    @State private var fps: Double = 30
    @State private var countdown = 0

    private var big: CGFloat { rainMode ? 1.35 : 1.0 }

    var body: some View {
        Group {
            if !onboarded {
                OnboardingView { onboarded = true }
            } else {
                cameraScreen
            }
        }
        .onAppear { cam.requestAndConfigure(); cam.startRunning(); cam.dualSave = dualSave; cam.useRAW = useRAW }
        .onDisappear { cam.stopRunning() }
    }

    private var cameraScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(manager: cam)
                .ignoresSafeArea()
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { v in
                        if cam.trackingOn { cam.enableTapTracking(atLayerPoint: v.location) }
                        else { cam.focusAndExpose(atLayerPoint: v.location) }
                    }
                )

            overlays

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
                Spacer()
                if proMode { proPanel }
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
        .sheet(isPresented: $showTools) { toolsSheet }
        .sheet(isPresented: $showGallery) { GalleryView(manager: cam) }
        .sheet(isPresented: $showHelp) { HelpView() }
    }

    // MARK: Overlays
    @ViewBuilder private var overlays: some View {
        GeometryReader { geo in
            ZStack {
                if showGrid {
                    GridOverlay().stroke(.white.opacity(0.35), lineWidth: 1)
                }
                if showZebra {
                    // Simple highlight-warning indicator: red hatch in the brightest histogram zone is
                    // represented as a labeled chip; full per-pixel zebra needs a Metal shader (v2).
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
                if showLevel {
                    let level = abs(cam.levelDegrees) < 1.5
                    VStack {
                        Spacer()
                        ZStack {
                            Capsule().fill(.white.opacity(0.25)).frame(width: 130, height: 4)
                            Capsule().fill(level ? .green : .yellow).frame(width: 44, height: 4)
                                .offset(x: CGFloat(max(min(cam.levelDegrees, 30), -30)) * 1.4)
                        }
                        Text(level ? "Level ✓" : String(format: "Tilt %.0f°", cam.levelDegrees)).font(.caption2)
                        Spacer().frame(height: 190)
                    }
                }
                if showHistogram {
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(0..<16, id: \.self) { i in
                            Rectangle().fill(.white.opacity(0.85)).frame(width: 7, height: CGFloat(cam.histogram[i]) * 900 + 2)
                        }
                    }
                    .padding(6).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .position(x: geo.size.width - 80, y: 110)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Top bar
    private var topBar: some View {
        HStack(spacing: 12) {
            Label(cam.batteryPercent >= 0 ? "\(cam.batteryPercent)%" : "--%", systemImage: "battery.75")
                .font(.subheadline.bold())
                .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.55), in: Capsule())
            if cam.trackingOn {
                Label("TRACKING ON", systemImage: "scope").font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 5).background(.yellow, in: Capsule()).foregroundStyle(.black)
            }
            if cam.isRecording {
                Label(String(format: "%02d:%02d", cam.recordingSeconds / 60, cam.recordingSeconds % 60), systemImage: "record.circle.fill")
                    .font(.subheadline.bold()).foregroundStyle(.red)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.55), in: Capsule())
            }
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
                        preset = p
                        if p == .video || p == .vlog { isVideoMode = true }
                        cam.applyPreset(p)
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
        countdown = 3
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            countdown -= 1
            if countdown <= 0 { t.invalidate(); cam.capturePhoto() }
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
                Section("Easy wins") {
                    Toggle("Dual Save — backup copy in the app + Photos (like 2 memory cards)", isOn: $dualSave)
                        .onChange(of: dualSave) { _, v in cam.dualSave = v }
                    Toggle("Rain / Glove Mode — extra-big buttons", isOn: $rainMode)
                    Toggle("Battery Saver — slows the pro tools to save power", isOn: $batterySaver)
                        .onChange(of: batterySaver) { _, v in cam.batterySaver = v }
                    Toggle("Subject Tracking", isOn: Binding(get: { cam.trackingOn }, set: { cam.trackingOn = $0 }))
                }
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
