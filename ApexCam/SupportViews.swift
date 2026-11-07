import SwiftUI
import AVFoundation
import UIKit

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
                            ForEach(files, id: \.self) { url in ThumbView(url: url) }
                        }.padding(6)
                    }
                }
            }
            .navigationTitle("Your shots (app backup)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: reload)
            .onChange(of: manager.lastSavedTick) { _, _ in reload() }
        }
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
