//
//  LiquidGlass.swift
//  MergeRequestMonitor
//

import AppKit
import SwiftUI
import components_swiftUI

extension View {
    /// Floating panel shell: Liquid Glass over a frosted underlay so text stays readable.
    @ViewBuilder
    func liquidGlassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .background {
                    shape.fill(Semantic.Colors.backgroundColorElevated.opacity(0.88))
                }
                .glassEffect(
                    .regular.tint(Semantic.Colors.backgroundColorElevated.opacity(0.55)),
                    in: shape
                )
        } else {
            self
                .background {
                    VisualEffectView(material: .popover, blendingMode: .behindWindow)
                    shape.fill(Semantic.Colors.backgroundColorElevated.opacity(0.72))
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(Semantic.Colors.subtleOutlineColor.opacity(0.55), lineWidth: 1)
                }
        }
    }

    /// Compact control chip: denser material so badges stay legible on glass.
    func liquidGlassChip() -> some View {
        liquidGlassChip(in: Capsule())
    }

    func liquidGlassChip<S: InsettableShape>(in shape: S) -> some View {
        background {
            shape.fill(.regularMaterial)
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    /// Soft pressed / hovered wash — opaque enough not to muddy row text.
    func liquidGlassHighlight(
        isPressed: Bool,
        isHovered: Bool = false,
        cornerRadius: CGFloat
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fillOpacity: Double = isPressed ? 0.1 : (isHovered ? 0.05 : 0)
        return background {
            shape
                .fill(Semantic.Colors.notBlack.opacity(fillOpacity))
                .animation(.easeOut(duration: isPressed ? 0.09 : 0.18), value: fillOpacity)
        }
    }
}

/// AppKit vibrancy used before Liquid Glass APIs exist.
private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
