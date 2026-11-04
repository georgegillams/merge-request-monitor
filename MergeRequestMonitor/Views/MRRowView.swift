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
                HStack(alignment: .top, spacing: Primitive.Layout.spacingSm) {
                    if isStacked {
                        StackBranchMark()
                    }
                    titleAndStatus
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
        .overlay(alignment: showsDetails ? .bottomTrailing : .trailing) {
            copyActions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .liquidGlassHighlight(
            isPressed: isPressed,
            isHovered: isHovered,
            cornerRadius: Primitive.Layout.borderRadiusSm
        )
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

    /// Status shares the title row when it fits in half the width, or when a short
    /// title plus status still fit on one line. Otherwise status moves underneath.
    @ViewBuilder
    private var titleAndStatus: some View {
        let title = Text(parsedTitle.displayTitle)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Semantic.Colors.notBlack)
            .lineLimit(1)
            .truncationMode(.tail)
            .hoverTooltip(parsedTitle.fullTitle)
            .accessibilityLabel(parsedTitle.fullTitle)

        if showsDetails {
            TitleStatusRowLayout(spacing: Primitive.Layout.spacingSm) {
                title
                // Hidden line sizes the slot; live dots overlay so their buttons are
                // not nested inside the row's open-MR button.
                StatusLine(
                    stages: item.isMerged ? [] : item.stages,
                    approvals: item.isMerged ? nil : item.approvals,
                    mergeIndicator: item.mergeIndicator,
                    interactive: false
                )
                .hidden()
                .overlay(alignment: .topTrailing) {
                    statusLine
                }
            }
        } else {
            title
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .liquidGlassChip()
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
            .liquidGlassChip()
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
        .liquidGlassChip()
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

/// Status sits beside the title when they fit on one line — either because status is
/// within half the row (title may truncate), or because the title is short enough that
/// title + status fit together. Otherwise the title takes the full row and status moves
/// underneath — still on one trailing line when it fits the full width, or wrapping
/// across the full row if not.
private struct TitleStatusRowLayout: Layout {
    var spacing: CGFloat

    private enum Arrangement {
        /// Title and status on one row; status is trailing.
        case inline(titleSize: CGSize, statusSize: CGSize)
        /// Full-width title; status on the next line (trailing if one line, else full wrap).
        case stacked(titleSize: CGSize, statusSize: CGSize, fillsRow: Bool)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        let width = proposal.width ?? 0
        switch arrangement(title: subviews[0], status: subviews[1], rowWidth: width) {
        case let .inline(titleSize, statusSize):
            return CGSize(width: width, height: max(titleSize.height, statusSize.height))
        case let .stacked(titleSize, statusSize, _):
            let gap = statusSize.height > 0 ? spacing : 0
            return CGSize(width: width, height: titleSize.height + gap + statusSize.height)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: proposal)
            return
        }
        switch arrangement(title: subviews[0], status: subviews[1], rowWidth: bounds.width) {
        case let .inline(titleSize, statusSize):
            let titleWidth = max(0, bounds.width - spacing - statusSize.width)
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: titleWidth, height: titleSize.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - statusSize.width, y: bounds.minY),
                proposal: ProposedViewSize(statusSize)
            )
        case let .stacked(titleSize, statusSize, fillsRow):
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: bounds.width, height: titleSize.height)
            )
            let statusWidth = fillsRow ? bounds.width : min(statusSize.width, bounds.width)
            subviews[1].place(
                at: CGPoint(
                    x: fillsRow ? bounds.minX : bounds.maxX - statusWidth,
                    y: bounds.minY + titleSize.height + spacing
                ),
                proposal: ProposedViewSize(width: statusWidth, height: statusSize.height)
            )
        }
    }

    private func arrangement(title: LayoutSubview, status: LayoutSubview, rowWidth: CGFloat) -> Arrangement {
        let halfWidth = max(0, (rowWidth - spacing) / 2)
        let idealTitle = title.sizeThatFits(.unspecified)
        let idealStatus = status.sizeThatFits(.unspecified)
        let titleSizeFull = title.sizeThatFits(ProposedViewSize(width: rowWidth, height: nil))

        let statusFitsInHalf = idealStatus.width <= halfWidth
        let titleAndStatusFitTogether = idealTitle.width + spacing + idealStatus.width <= rowWidth
        if statusFitsInHalf || titleAndStatusFitTogether {
            let titleWidth = max(0, rowWidth - spacing - idealStatus.width)
            let titleSize = title.sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
            return .inline(titleSize: titleSize, statusSize: idealStatus)
        }

        if idealStatus.width <= rowWidth {
            return .stacked(titleSize: titleSizeFull, statusSize: idealStatus, fillsRow: false)
        }

        let wrappedStatus = status.sizeThatFits(ProposedViewSize(width: rowWidth, height: nil))
        return .stacked(
            titleSize: titleSizeFull,
            statusSize: CGSize(width: rowWidth, height: wrappedStatus.height),
            fillsRow: true
        )
    }
}

/// Lays out children left-to-right, wrapping onto new lines when the proposed width is tight.
private struct WrappingHStackLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for index in subviews.indices {
            let frame = result.frames[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private struct Arrangement {
        var size: CGSize
        var frames: [CGRect]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> Arrangement {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            usedWidth = max(usedWidth, x - spacing)
        }

        let width = maxWidth.isFinite ? min(usedWidth, maxWidth) : usedWidth
        return Arrangement(
            size: CGSize(width: width, height: y + rowHeight),
            frames: frames
        )
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
    private static let lineSpacing: CGFloat = 4
    private static let approvalGap: CGFloat = 10

    var body: some View {
        WrappingHStackLayout(spacing: Self.dotSpacing, lineSpacing: Self.lineSpacing) {
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
