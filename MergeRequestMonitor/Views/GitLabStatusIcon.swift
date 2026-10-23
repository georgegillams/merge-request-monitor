//
//  GitLabStatusIcon.swift
//  MergeRequestMonitor
//

import SwiftUI

private struct StatusSymbolsOutdatedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set when the latest fetch is over a minute old. Status marks draw at half opacity.
    var statusSymbolsOutdated: Bool {
        get { self[StatusSymbolsOutdatedKey.self] }
        set { self[StatusSymbolsOutdatedKey.self] = newValue }
    }
}

/// GitLab CI status mark. The glyphs are GitLab's borderless status icons, tinted here.
/// Pipeline marks use a light outer circle, an inner circle, and that glyph.
/// Approved reviews use a dark green outline and tick with a clear fill.
/// Unapproved / partially approved reviews use a long-dashed grey ring instead.
struct GitLabStatusIcon: View {
    enum Kind: Equatable {
        case status(PipelineStageStatus)
        case approved
        case partiallyApproved
        case unapproved
        /// Outline purple merge mark for an MR currently on a merge train.
        case mergeTrain
        /// Filled purple merge mark for a recently merged MR.
        case merged
    }

    let kind: Kind
    var size: CGFloat = 18

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.statusSymbolsOutdated) private var statusSymbolsOutdated

    var body: some View {
        let style = Self.style(for: kind, colorScheme: colorScheme)
        ZStack {
            switch style.ring {
            case .filled:
                Circle()
                    .fill(style.outer)
                Circle()
                    .fill(style.inner)
                    .padding(size * 2 / 14)
            case .outline:
                Circle()
                    .strokeBorder(style.outer, lineWidth: size * 2 / 14)
            case .dashed:
                Circle()
                    .strokeBorder(
                        style.outer,
                        style: StrokeStyle(
                            lineWidth: size * 2 / 14,
                            lineCap: .round,
                            dash: [size * 0.18, size * 0.28]
                        )
                    )
            }
            symbol(style)
        }
        .frame(width: size, height: size)
        .opacity(statusSymbolsOutdated ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.2), value: statusSymbolsOutdated)
        .accessibilityHidden(true)
    }

    static func accent(for kind: Kind, colorScheme: ColorScheme) -> Color {
        style(for: kind, colorScheme: colorScheme).accent
    }

    @ViewBuilder
    private func symbol(_ style: Style) -> some View {
        if let asset = style.asset {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(style.symbol)
        } else if let systemImage = style.systemImage {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(style.symbol)
        }
    }

    private struct Style {
        var outer: Color
        var inner: Color
        var symbol: Color
        var accent: Color
        var asset: String? = nil
        var systemImage: String? = nil
        var ring: Ring = .filled
    }

    private enum Ring {
        /// Light outer disc with a contrasting inner disc (pipeline stages).
        case filled
        /// Solid outer stroke and a clear center (approved reviews).
        case outline
        /// Long-dash outline (unapproved / partial approval).
        case dashed
    }

    /// Ring width matches GitLab's 14px status icon, thickened slightly so the light circle reads at this size.
    private static func style(for kind: Kind, colorScheme: ColorScheme) -> Style {
        let hole = colorScheme == .dark ? Color.black : Color.white
        switch kind {
        case .status(let status):
            return style(for: status, hole: hole, colorScheme: colorScheme)
        case .approved:
            return Style(
                outer: Palette.greenDark,
                inner: .clear,
                symbol: Palette.greenDark,
                accent: Palette.greenDark,
                asset: "CIStatusSuccess",
                ring: .outline
            )
        case .partiallyApproved:
            return Style(
                outer: Palette.greyLight,
                inner: hole,
                symbol: Palette.grey,
                accent: Palette.grey,
                asset: "CIStatusSuccess",
                ring: .dashed
            )
        case .unapproved:
            return Style(
                outer: Palette.greyLight,
                inner: hole,
                symbol: Palette.grey,
                accent: Palette.grey,
                ring: .dashed
            )
        case .mergeTrain:
            return Style(
                outer: Palette.purple,
                inner: .clear,
                symbol: Palette.purple,
                accent: Palette.purple,
                asset: "MergeStatus",
                ring: .outline
            )
        case .merged:
            return Style(
                outer: Palette.purpleLight,
                inner: Palette.purple,
                symbol: .white,
                accent: Palette.purple,
                asset: "MergeStatus"
            )
        }
    }

    private static func style(for status: PipelineStageStatus, hole: Color, colorScheme: ColorScheme) -> Style {
        let darkNeutral = colorScheme == .dark
        switch status {
        case .success:
            return Style(
                outer: Palette.greenLight,
                inner: Palette.greenDark,
                symbol: .white,
                accent: Palette.greenDark,
                asset: "CIStatusSuccess"
            )
        case .failed:
            return Style(
                outer: Palette.redLight,
                inner: Palette.redDark,
                symbol: .white,
                accent: Palette.redDark,
                asset: "CIStatusFailed"
            )
        case .inProgress:
            return Style(
                outer: Palette.blueLight,
                inner: hole,
                symbol: Palette.blue,
                accent: Palette.blue,
                asset: "CIStatusRunning"
            )
        case .paused:
            return Style(
                outer: Palette.yellowLight,
                inner: Palette.yellowDark,
                symbol: .white,
                accent: Palette.yellowDark,
                asset: "CIStatusPaused"
            )
        case .created:
            return Style(
                outer: Palette.greyMid,
                inner: hole,
                symbol: darkNeutral ? Palette.greyLight : Palette.greyDark,
                accent: Palette.greyMid,
                asset: "CIStatusCreated"
            )
        case .skipped:
            return Style(
                outer: Palette.greyLight,
                inner: hole,
                symbol: darkNeutral ? Palette.greyLight : Palette.grey,
                accent: Palette.grey,
                asset: "CIStatusSkipped"
            )
        case .manual:
            return Style(
                outer: Palette.greyLight,
                inner: hole,
                symbol: darkNeutral ? Palette.greyLight : Palette.grey,
                accent: Palette.grey,
                asset: "CIStatusManual"
            )
        case .cancelled:
            return Style(
                outer: Palette.greyLight,
                inner: hole,
                symbol: darkNeutral ? Palette.greyLight : Palette.grey,
                accent: Palette.grey,
                asset: "CIStatusCanceled"
            )
        case .unknown:
            return Style(
                outer: Palette.greyLight,
                inner: hole,
                symbol: darkNeutral ? Palette.greyLight : Palette.greyDark,
                accent: Palette.grey,
                systemImage: "questionmark"
            )
        }
    }

    /// GitLab Pajamas light-mode status colors. The artwork itself stays uncolored.
    private enum Palette {
        static let greenLight = Color(red: 145.0 / 255, green: 212.0 / 255, blue: 168.0 / 255)
        static let greenDark = Color(red: 16.0 / 255, green: 133.0 / 255, blue: 72.0 / 255)
        static let redLight = Color(red: 252.0 / 255, green: 181.0 / 255, blue: 170.0 / 255)
        static let redDark = Color(red: 221.0 / 255, green: 43.0 / 255, blue: 14.0 / 255)
        static let blueLight = Color(red: 157.0 / 255, green: 199.0 / 255, blue: 241.0 / 255)
        static let blue = Color(red: 31.0 / 255, green: 117.0 / 255, blue: 203.0 / 255)
        static let yellowLight = Color(red: 233.0 / 255, green: 190.0 / 255, blue: 116.0 / 255)
        static let yellowDark = Color(red: 171.0 / 255, green: 97.0 / 255, blue: 0.0 / 255)
        static let greyLight = Color(red: 200.0 / 255, green: 200.0 / 255, blue: 204.0 / 255)
        static let greyMid = Color(red: 138.0 / 255, green: 138.0 / 255, blue: 144.0 / 255)
        static let grey = Color(red: 115.0 / 255, green: 114.0 / 255, blue: 120.0 / 255)
        static let greyDark = Color(red: 78.0 / 255, green: 76.0 / 255, blue: 84.0 / 255)
        /// GitLab Pajamas `purple.200` / `purple.500`.
        static let purpleLight = Color(red: 203.0 / 255, green: 187.0 / 255, blue: 242.0 / 255)
        static let purple = Color(red: 123.0 / 255, green: 88.0 / 255, blue: 207.0 / 255)
    }
}
