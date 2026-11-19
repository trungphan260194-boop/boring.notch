//
//  NotchEnhancements.swift
//  boringNotch
//
//  Liquid Glass backdrop for Boring Notch Lite VN
//

import AppKit
import SwiftUI

struct NotchGlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var tintOpacity: Double = 0.42

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.appearance = NSAppearance(named: .darkAqua)
    }
}

struct NotchSurfaceBackground: View {
    let isOpen: Bool
    let useGlass: Bool
    let shape: NotchShape

    var body: some View {
        if isOpen && useGlass {
            ZStack {
                NotchGlassBackdrop(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.45)
            }
            .overlay {
                shape
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
            }
        } else {
            Color.black
        }
    }
}
