//
//  MRRowView.swift
//  MergeRequestMonitor
//

import AppKit
import SwiftUI
import components_swiftUI

struct MRRowView: View {
    let item: MergeRequestItem
    let showInstanceLabel: Bool
    var titleParsing: TitleParsing = .conventionalCommits
    var showThreadBadges: Bool = true
    /// True when this row is nested under another MR it is stacked on.
    var isStacked: Bool = false
    /// False for a ready stack parent shown in Draft: title and copy actions only.
    var showsDetails: Bool = true
    var onOpen: (() -> Void)? = nil
    var onOpenURL: ((URL) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var isHovered = false
    @State private var copiedField: CopyableField?
    @State private var copiedResetTask: Task<Void, Never>?

    private var parsedTitle: ParsedMergeRequestTitle {
        ParsedMergeRequestTitle.parse(rawTitle: item.title, parsing: titleParsing)
    }

    private var statusLine: StatusLine {
        StatusLine(
            stages: item.isMerged ? [] : item.stages,
            approvals: item.isMerged ? nil : item.approvals,
            mergeIndicator: item.mergeIndicator,
            onOpenURL: onOpenURL
        )
    }

    var body: some View {
        Button(action: { onOpen?() }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: Primitive.Layout.spacingSm) {
                    if isStacked {
                        StackBranchMark()
                    }
                    Text(parsedTitle.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Semantic.Colors.notBlack)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hoverTooltip(parsedTitle.fullTitle)
                        .accessibilityLabel(parsedTitle.fullTitle)

                    if showsDetails {
                        // Reserves the title row's trailing space. The live dots are an overlay
                        // so their buttons are not nested inside this one.
                        StatusLine(
                            stages: item.isMerged ? [] : item.stages,
                            approvals: item.isMerged ? nil : item.approvals,
                            mergeIndicator: item.mergeIndicator,
                            interactive: false
                        )
                        .hidden()
                    }
                }

                if showsDetails {
                    HStack(spacing: Primitive.Layout.spacingSm) {
                        if isStacked {
                            Color.clear
                                .frame(width: StackBranchMark.width, height: 1)
                        }
                        if showInstanceLabel {
                            Text(item.instanceLabel)
                        }
                        Text(item.projectPath)
                            .layoutPriority(-1)
                        Text("!\(item.iid)")
                            .fixedSize()
                            .layoutPriority(1)
                        if parsedTitle.isDraft {
                            DraftBadge()
                                .fixedSize()
                                .layoutPriority(1)
                        }
                        if showThreadBadges, item.threads.hasThreads {
                            ThreadsBadge(threads: item.threads)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Semantic.Colors.textDisabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The title is often narrower than the row. Without this, macOS hit-tests
            // only the text, so the rest of the row does nothing.
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(isPressed: $isPressed))
        .accessibilityHint(isStacked ? "Stacked merge request. Open in browser" : "Open in browser")
        .overlay(alignment: .topTrailing) {
            if showsDetails {
                statusLine
            }
        }
        .overlay(alignment: showsDetails ? .bottomTrailing : .trailing) {
            copyActions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Primitive.Layout.borderRadiusSm, style: .continuous)
                .fill(Semantic.Colors.notBlack.opacity(isPressed ? 0.1 : 0))
        }
        .onPointerHover($isHovered)
        .onChange(of: isHovered) { hovered in
            if !hovered {
                copiedResetTask?.cancel()
                copiedField = nil
            }
        }
        .scaleEffect(!reduceMotion && isPressed ? 0.98 : 1)
        .animation(.easeOut(duration: isPressed ? 0.09 : 0.18), value: isPressed)
        .padding(.horizontal, -8)
        .padding(.vertical, -6)
        .accessibilityElement(children: .contain)
        .accessibilityValue(showsDetails ? item.mergeIndicator.tooltip : "")
    }

    @ViewBuilder
    private var copyActions: some View {
        if item.webURL != nil || !item.sourceBranch.isEmpty {
            HStack(spacing: 3) {
                if item.webURL != nil {
                    copyButton(.link)
                }
                if !item.sourceBranch.isEmpty {
                    copyButton(.branch)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                Capsule()
                    .fill(Semantic.Colors.backgroundColorElevated)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        }
    }

    private func copyButton(_ field: CopyableField) -> some View {
        let copied = copiedField == field
        return Button {
            copy(field)
        } label: {
            Image(systemName: copied ? "checkmark" : field.systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Semantic.Colors.notBlack)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip(copied ? "Copied" : field.label)
        .accessibilityLabel(copied ? "Copied" : field.label)
    }

    private func copy(_ field: CopyableField) {
        let value: String
        switch field {
        case .link:
            guard let url = item.webURL else { return }
            value = url.absoluteString
        case .branch:
            value = item.sourceBranch
            guard !value.isEmpty else { return }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedField = field
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if copiedField == field {
                copiedField = nil
            }
        }
    }
}

private enum CopyableField: Equatable {
    case link
    case branch

    var systemImage: String {
        switch self {
        case .link: return "link"
        case .branch: return "arrow.triangle.branch"
        }
    }

    var label: String {
        switch self {
        case .link: return "Copy link"
        case .branch: return "Copy branch"
        }
    }
}

/// Corner mark that shows a row is stacked under the merge request above it.
private struct StackBranchMark: View {
    static let width: CGFloat = 10

    var body: some View {
        StackBranchShape()
            .stroke(
                Semantic.Colors.textDisabled,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
            .frame(width: Self.width, height: 12)
            .accessibilityHidden(true)
    }
}

private struct StackBranchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let insetX = rect.minX + 1
        path.move(to: CGPoint(x: insetX, y: rect.minY))
        path.addLine(to: CGPoint(x: insetX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct DraftBadge: View {
    var body: some View {
        Text("Draft")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Semantic.Colors.notBlack)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                Capsule()
                    .fill(Semantic.Colors.notBlack.opacity(0.14))
            }
            .accessibilityLabel("Draft")
    }
}

private struct ThreadsBadge: View {
    let threads: ThreadSummary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("\(threads.resolved)/\(threads.resolvable)")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(Semantic.Colors.notBlack)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background {
            Capsule()
                .fill(Semantic.Colors.notBlack.opacity(0.14))
        }
        .hoverTooltip(threads.displayText)
        .accessibilityLabel(threads.displayText)
    }
}

/// Reports mouse-down on the card. The pressed chrome is drawn around the row, including
/// the status dots, which sit outside this button.
private struct CardPressStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed in
                isPressed = pressed
            }
            .contentShape(Rectangle())
    }
}

/// Stage circles, then the review circle, then an optional merge mark.
/// A fully green line means the MR can merge. Merged rows show only the solid merge mark.
private struct StatusLine: View {
    let stages: [PipelineStage]
    let approvals: ApprovalSummary?
    var mergeIndicator: MergeIndicator = .none
    var interactive: Bool = true
    var onOpenURL: ((URL) -> Void)? = nil

    private enum PresentedPopover: Equatable {
        case stage(String)
        case reviews
    }

    @State private var presentedPopover: PresentedPopover?
    @Environment(\.statusSymbolsOutdated) private var statusSymbolsOutdated

    private static let dotSpacing: CGFloat = 5
    private static let approvalGap: CGFloat = 10

    var body: some View {
        HStack(spacing: Self.dotSpacing) {
            ForEach(stages) { stage in
                stageControl(stage)
            }

            if let approvals {
                reviewControl(approvals)
                    .padding(.leading, stages.isEmpty ? 0 : Self.approvalGap)
            }

            if let mergeKind = mergeIndicator.iconKind {
                StatusDot(
                    kind: mergeKind,
                    tooltip: mergeIndicator.tooltip,
                    showsTooltip: interactive
                )
                .padding(
                    .leading,
                    (stages.isEmpty && approvals == nil) ? 0 : Self.approvalGap
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityElement(children: interactive ? .contain : .ignore)
    }

    @ViewBuilder
    private func stageControl(_ stage: PipelineStage) -> some View {
        let dot = StatusDot(
            kind: .status(stage.status),
            tooltip: "\(stage.name) — \(stage.status.helpText)",
            isHighlighted: interactive && presentedPopover == .stage(stage.id),
            showsTooltip: interactive
        )

        if interactive {
            Button {
                presentedPopover = .stage(stage.id)
            } label: {
                dot
            }
            .buttonStyle(.plain)
            .disabled(stage.jobs.isEmpty)
            .accessibilityHint(stage.jobs.isEmpty ? "" : "Show jobs in \(stage.name)")
            .popover(
                isPresented: stagePopoverBinding(for: stage.id),
                arrowEdge: .bottom
            ) {
                StageJobsPopover(stage: stage, onOpenURL: onOpenURL)
                    .environment(\.statusSymbolsOutdated, statusSymbolsOutdated)
            }
        } else {
            dot
        }
    }

    @ViewBuilder
    private func reviewControl(_ approvals: ApprovalSummary) -> some View {
        let dot = StatusDot(
            kind: approvals.iconKind,
            tooltip: approvals.tooltip,
            isHighlighted: interactive && presentedPopover == .reviews,
            showsTooltip: interactive
        )

        if interactive {
            Button {
                presentedPopover = .reviews
            } label: {
                dot
            }
            .buttonStyle(.plain)
            .accessibilityHint("Show reviews")
            .popover(
                isPresented: reviewsPopoverBinding,
                arrowEdge: .bottom
            ) {
                ReviewsPopover(approvals: approvals)
            }
        } else {
            dot
        }
    }

    private func stagePopoverBinding(for stageID: String) -> Binding<Bool> {
        Binding(
            get: { presentedPopover == .stage(stageID) },
            set: { isPresented in
                if isPresented {
                    presentedPopover = .stage(stageID)
                } else if presentedPopover == .stage(stageID) {
                    presentedPopover = nil
                }
            }
        )
    }

    private var reviewsPopoverBinding: Binding<Bool> {
        Binding(
            get: { presentedPopover == .reviews },
            set: { isPresented in
                if isPresented {
                    presentedPopover = .reviews
                } else if presentedPopover == .reviews {
                    presentedPopover = nil
                }
            }
        )
    }
}

private struct StageJobsPopover: View {
    let stage: PipelineStage
    var onOpenURL: ((URL) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Stage: \(stage.name)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Semantic.Colors.textDisabled)
                .padding(.horizontal, Primitive.Layout.spacingBase)
                .padding(.top, Primitive.Layout.spacingSm)
                .padding(.bottom, 6)

            ForEach(stage.jobs) { job in
                let canOpen = job.webURL != nil && onOpenURL != nil
                let tip = canOpen ? "Open \(job.name) in browser" : job.status.helpText
                Button {
                    if let url = job.webURL {
                        onOpenURL?(url)
                    }
                } label: {
                    HStack(spacing: Primitive.Layout.spacingSm) {
                        Text(job.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Semantic.Colors.notBlack)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: Primitive.Layout.spacingSm)

                        GitLabStatusIcon(kind: .status(job.status), size: 18)
                            .frame(width: 18, height: 18)
                    }
                    .padding(.horizontal, Primitive.Layout.spacingBase)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canOpen)
                .accessibilityHint(tip)
            }
        }
        .frame(minWidth: 220, maxWidth: 280)
        .padding(.bottom, Primitive.Layout.spacingSm)
    }
}

private struct ReviewsPopover: View {
    let approvals: ApprovalSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reviews: \(approvals.displayText)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Semantic.Colors.textDisabled)
                .padding(.horizontal, Primitive.Layout.spacingBase)
                .padding(.top, Primitive.Layout.spacingSm)
                .padding(.bottom, approvals.approvedBy.isEmpty ? 0 : 6)

            ForEach(Array(approvals.approvedBy.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Semantic.Colors.notBlack)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Primitive.Layout.spacingBase)
                    .padding(.vertical, 7)
            }
        }
        .frame(minWidth: 220, maxWidth: 280)
        .padding(.bottom, Primitive.Layout.spacingSm)
    }
}

private struct StatusDot: View {
    let kind: GitLabStatusIcon.Kind
    let tooltip: String
    var isHighlighted: Bool = false
    var showsTooltip: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let accent = GitLabStatusIcon.accent(for: kind, colorScheme: colorScheme)
        let symbol = GitLabStatusIcon(kind: kind, size: 20)
            .frame(width: 20, height: 20)
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHighlighted ? accent.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())

        if showsTooltip {
            symbol
                .hoverTooltip(tooltip)
                .accessibilityLabel(tooltip)
                .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
        } else {
            symbol
        }
    }
}

private extension MergeIndicator {
    var iconKind: GitLabStatusIcon.Kind? {
        switch self {
        case .none: return nil
        case .mergeTrain: return .mergeTrain
        case .merged: return .merged
        }
    }
}

private extension ApprovalSummary {
    var approvedCount: Int {
        if let required = approvalsRequired, required > 0 {
            let left = approvalsLeft ?? max(0, required - approvedBy.count)
            return max(approvedBy.count, max(0, required - left))
        }
        return approvedBy.count
    }

    var isFullyApproved: Bool {
        if let required = approvalsRequired, required > 0 {
            return (approvalsLeft ?? 0) == 0
        }
        return !approvedBy.isEmpty
    }

    /// Some approvals in, and more than one was required (so the MR is only partway there).
    var isPartiallyApproved: Bool {
        guard !isFullyApproved else { return false }
        guard let required = approvalsRequired, required > 1 else { return false }
        return approvedCount > 0
    }

    var iconKind: GitLabStatusIcon.Kind {
        if isFullyApproved {
            return .approved
        }
        if isPartiallyApproved {
            return .partiallyApproved
        }
        return .unapproved
    }

    var tooltip: String {
        let names = approvedBy.joined(separator: ", ")
        if names.isEmpty {
            return displayText
        }
        return "\(displayText) — \(names)"
    }
}
