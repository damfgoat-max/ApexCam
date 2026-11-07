import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var manager: CameraManager

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = manager.session
        v.previewLayer.videoGravity = .resizeAspectFill
        manager.previewLayer = v.previewLayer
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        manager.previewLayer = uiView.previewLayer
        if let conn = uiView.previewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
    }
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
