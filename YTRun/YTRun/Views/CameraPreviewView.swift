//
//  CameraPreviewView.swift
//  YTRun
//

import SwiftUI
import AVFoundation

// Plain `AVCaptureVideoPreviewLayer` wrapper — SwiftUI has no native
// camera-preview view, so this is the standard bridge, same shape as
// any UIKit-backed component elsewhere in the app.
struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {}

    final class PreviewContainerView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                guard let previewLayer else { return }
                previewLayer.frame = bounds
                layer.addSublayer(previewLayer)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
}
