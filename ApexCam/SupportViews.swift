import SwiftUI
import AVFoundation
import UIKit
import LocalAuthentication
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos

struct OnboardingView: View {
    var done: () -> Void
    @State private var page = 0
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                TabView(selection: $page) {
                    pageView(icon: "camera.fill", title: "Just point & shoot",
                             text: "ApexCam Pro starts in AUTO. One big button takes the photo. That's it — no settings needed.")
                        .tag(0)
                    pageView(icon: "figure.run", title: "Pick what you're shooting",
                             text: "Sports, Portrait, Night, Vlog — tap a preset and the app sets everything for you. Sports freezes motion, Night brightens the dark, Vlog flips to the front camera.")
                        .tag(1)
                    pageView(icon: "slider.horizontal.3", title: "Go PRO when you want",
                             text: "Tap PRO for big, simple dials: brightness, shutter speed, ISO, focus and zoom. Tap “Back to Auto” anytime. Your shots save to Photos — and with Dual Save, a backup copy stays in the app too.")
                        .tag(2)
                }
                .tabViewStyle(.page)
                Button {
                    if page < 2 { page += 1 } else { done() }
                } label: {
                    Text(page < 2 ? "Next" : "Start shooting 📸")
                        .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 60)
                        .background(Color.cyan, in: Capsule()).foregroundStyle(.black)
                }
                .padding(.horizontal, 24).padding(.bottom, 28)
            }
        }
        .foregroundStyle(.white)
    }
    private func pageView(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: icon).font(.system(size: 84)).foregroundStyle(.cyan)
            Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text(text).font(.title3).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 30)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    private let rows: [(String, String)] = [
        ("Auto", "The app picks everything. Best for most shots."),
        ("Sports / Motion", "Uses a very fast shutter (1/1000) so moving people don't blur."),
        ("Portrait", "Turns on face tracking so the person stays sharp."),
        ("Night", "Slows the shutter and raises ISO so dark scenes come out brighter. Hold still!"),
        ("Vlog", "Front camera, mirror view, smooth video, and a 3-second countdown for photos."),
        ("Macro", "Close-up focus for small things. Get close, tap to focus."),
        ("ISO", "How sensitive the camera is to light. Higher = brighter in the dark, but grainier."),
        ("Shutter speed", "How long the camera 'blinks'. Fast (1/2000) freezes action. Slow (1/30) is brighter but blurry if you move."),
        ("White Balance (K)", "Fixes colors. Low K = warmer/orange light, high K = daylight/blue."),
        ("EV / Brightness", "Just makes the shot brighter (+) or darker (−)."),
        ("Focus slider", "0 = very close, 1 = far away."),
        ("Stabilization", "Smooths shaky video. Cinematic Extended is the smoothest your phone offers."),
        ("Dual Save", "Like a pro camera's 2 memory cards: saves to Photos AND keeps a backup copy in this app's Gallery."),
        ("Volume buttons", "Pressing a volume button also takes a photo / stops video. Handy with gloves."),
        ("Battery Saver", "Slows the on-screen pro tools to use less power."),
        ("Magic: Auto-Capture", "In Tools > Magic Tools — the camera takes a photo by itself when big motion happens."),
        ("Magic: Smile Shutter", "Hold a face steady for about a second and it shoots by itself."),
        ("Magic: Clap Shutter", "Clap loudly and it takes the photo. Great hands-free."),
        ("Magic: Teleprompter", "Type your script in Tools and it scrolls over the front camera while you vlog."),
        ("Magic: Timelapse / Stop-Motion", "Timelapse shoots every few seconds. Stop-Motion shows a ghost of the last frame so you can line up the next one."),
        ("Magic: Private Vault", "In the Gallery — move shots behind Face ID / Touch ID."),
        ("Magic: Edit Studio", "Tap any photo in the Gallery to add filters and fix brightness, then save a copy."),
        ("Coach Tips", "Live tips at the top, like 'Too dark — tap the torch'. Based on real brightness, faces and tilt."),
        ("Golden Hour badge", "Approximate best-light time near sunset, from the date and rough location."),
        ("Location Stamp", "Writes GPS into the photo's hidden info (EXIF) when you turn it on."),
    ]
    var body: some View {
        NavigationStack {
            List(rows, id: \.0) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.0).font(.headline)
                    Text(r.1).font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 2)
            }
            .navigationTitle("What does it do?")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: CameraManager
    @State private var files: [URL] = []
    @State private var editURL: URL? = nil
    @State private var privateFiles: [URL] = []
    @State private var privateUnlocked = false
    @State private var privateNote = ""
    static func privateURL() -> URL {
        let v = CameraManager.vaultURL().appendingPathComponent("Private", isDirectory: true)
        try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        return v
    }
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 54)).foregroundStyle(.secondary)
                        Text("Nothing here yet").font(.title3.bold())
                        Text("Turn on Dual Save in Tools, then take a shot — a backup copy will show up here. Everything also saves to your Photos app.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                        Link("Open Photos app", destination: URL(string: "photos-redirect://")!)
                            .font(.headline)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 6) {
                            ForEach(files, id: \.self) { url in
                                ThumbView(url: url).onTapGesture {
                                    if !["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) { editURL = url }
                                }
                            }
                        }.padding(6)
                        Text("Tap a photo to open the Edit Studio ✂️").font(.caption).foregroundStyle(.secondary)
                        privateSection
                    }
                }
            }
            .navigationTitle("Your shots (app backup)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { editURL.map { EditItem(url: $0) } }, set: { editURL = $0?.url })) { item in
                EditStudioView(url: item.url)
            }
            .onAppear(perform: reload)
            .onChange(of: manager.lastSavedTick) { _, _ in reload() }
        }
    }
    @ViewBuilder private var privateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.cyan)
                Text("Private Vault").font(.headline)
                Spacer()
                if !files.isEmpty {
                    Button("Move newest shot here") { moveNewestToPrivate() }.font(.caption.bold())
                }
            }
            if privateUnlocked {
                if privateFiles.isEmpty {
                    Text("Nothing private yet. Move a shot here and it leaves the main gallery list.").font(.caption).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: cols, spacing: 6) {
                        ForEach(privateFiles, id: \.self) { url in ThumbView(url: url) }
                    }
                }
            } else {
                Button { unlockPrivate() } label: {
                    Label("Unlock with Face ID / Touch ID", systemImage: "faceid")
                        .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.cyan, in: Capsule()).foregroundStyle(.black)
                }.buttonStyle(.plain)
                if !privateNote.isEmpty { Text(privateNote).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
    }
    private func unlockPrivate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            privateNote = "Biometrics aren't set up on this phone (Settings > Face ID & Passcode), so the Private Vault stays locked."
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock your Private Vault") { ok, _ in
            DispatchQueue.main.async {
                privateUnlocked = ok
                if ok { loadPrivate() } else { privateNote = "That didn't match — tap to try again." }
            }
        }
    }
    private func loadPrivate() {
        privateFiles = (try? FileManager.default.contentsOfDirectory(at: GalleryView.privateURL(), includingPropertiesForKeys: nil)) ?? []
    }
    private func moveNewestToPrivate() {
        guard let newest = files.first else { return }
        let dest = GalleryView.privateURL().appendingPathComponent(newest.lastPathComponent)
        try? FileManager.default.moveItem(at: newest, to: dest)
        reload(); if privateUnlocked { loadPrivate() }
    }
    private func reload() {
        let vault = CameraManager.vaultURL()
        let all = (try? FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: [.creationDateKey])) ?? []
        files = all.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (a ?? .distantPast) > (b ?? .distantPast)
        }
    }
}

struct ThumbView: View {
    let url: URL
    @State private var image: UIImage? = nil
    var isVideo: Bool { ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) }
    var body: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.25)).aspectRatio(1, contentMode: .fit)
            if let image {
                Image(uiImage: image).resizable().scaledToFill().frame(minWidth: 0).clipped()
            } else if isVideo {
                Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
            if isVideo {
                VStack { Spacer(); HStack { Text("VIDEO").font(.caption2.bold()).padding(3).background(.black.opacity(0.6), in: Capsule()); Spacer() } }
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { load() }
    }
    private func load() {
        if isVideo {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.5, preferredTimescale: 600))]) { _, cg, _, _, _ in
                if let cg { DispatchQueue.main.async { image = UIImage(cgImage: cg) } }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                if let img = UIImage(contentsOfFile: url.path) { DispatchQueue.main.async { image = img } }
            }
        }
    }
}


struct EditItem: Identifiable { let url: URL; var id: String { url.path } }

struct EditStudioView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage? = nil
    @State private var filterName = "None"
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1
    @State private var note = ""
    private let filters = ["None", "Vivid", "Mono", "Noir", "Warm", "Cool", "Cinematic"]
    private func ci(_ name: String, _ img: CIImage, _ params: [String: Any] = [:]) -> CIImage {
        guard let f = CIFilter(name: name) else { return img }
        f.setValue(img, forKey: kCIInputImageKey)
        for (k, v) in params { f.setValue(v, forKey: k) }
        return f.outputImage ?? img
    }
    private var edited: UIImage? {
        guard let original, var img = CIImage(image: original) else { return original }
        switch filterName {
        case "Vivid": img = ci("CIPhotoEffectProcess", img)
        case "Mono": img = ci("CIPhotoEffectMono", img)
        case "Noir": img = ci("CIPhotoEffectNoir", img)
        case "Warm": img = ci("CITemperatureAndTint", img, [kCIInputNeutralKey: CIVector(x: 6500, y: 0), kCIInputTargetNeutralKey: CIVector(x: 4200, y: 0)])
        case "Cool": img = ci("CITemperatureAndTint", img, [kCIInputNeutralKey: CIVector(x: 6500, y: 0), kCIInputTargetNeutralKey: CIVector(x: 8500, y: 0)])
        case "Cinematic":
            img = ci("CIPhotoEffectFade", img)
            img = ci("CIVignette", img, [kCIInputIntensityKey: 0.7, kCIInputRadiusKey: 1.6])
        default: break
        }
        img = ci("CIColorControls", img, [kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: filterName == "Vivid" ? 1.25 : 1.0])
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return original }
        return UIImage(cgImage: cg, scale: original.scale, orientation: original.imageOrientation)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let edited {
                    Image(uiImage: edited).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14))
                } else { ProgressView() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filters, id: \.self) { f in
                            Button(f) { filterName = f }
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(filterName == f ? Color.cyan : Color.gray.opacity(0.25), in: Capsule())
                                .foregroundStyle(filterName == f ? .black : .primary).font(.subheadline.bold())
                        }
                    }.padding(.horizontal, 4)
                }
                HStack { Text("Brightness").font(.caption); Slider(value: $brightness, in: -0.3...0.3) }
                HStack { Text("Contrast").font(.caption); Slider(value: $contrast, in: 0.6...1.5) }
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                Button { saveCopy() } label: {
                    Text("Save edited copy").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                        .background(Color.cyan, in: Capsule()).foregroundStyle(.black)
                }.buttonStyle(.plain)
                Spacer()
            }
            .padding(16)
            .navigationTitle("Edit Studio")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { original = UIImage(contentsOfFile: url.path) }
        }
    }
    private func saveCopy() {
        guard let img = edited, let data = img.jpegData(compressionQuality: 0.9) else { return }
        let name = "ApexCam-Edit-\(Int(Date().timeIntervalSince1970)).jpg"
        try? data.write(to: CameraManager.vaultURL().appendingPathComponent(name))
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            if st == .authorized || st == .limited {
                PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: img) }) { ok, _ in
                    DispatchQueue.main.async { note = ok ? "Saved to Photos + app Gallery ✓ (original untouched)" : "Saved to app Gallery. Photos save failed." }
                }
            } else {
                DispatchQueue.main.async { note = "Saved to app Gallery. Photos permission is off." }
            }
        }
    }
}

