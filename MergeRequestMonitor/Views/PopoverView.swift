//
//  PopoverView.swift
//  MergeRequestMonitor
//

import SwiftUI
import AppKit
import components_swiftUI

struct PopoverView: View {
    @ObservedObject var coordinator: RefreshCoordinator
    @ObservedObject var settings: AppSettings
    var onOpenSettings: () -> Void
    @State private var selectedTab: MergeRequestListKind

    /// Matches `NSPopover` on macOS 27, whose frame resolves to a 20pt corner.
    private static let cornerRadius: CGFloat = 20

    init(
        coordinator: RefreshCoordinator,
        settings: AppSettings,
        onOpenSettings: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        _selectedTab = State(
            initialValue: settings.popoverTabPreference.initialTab(
                lastSelected: settings.lastPopoverTab
            )
        )
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsTabs {
                tabs
            }
            content
        }
        .frame(width: 420)
        .background(panelShape.fill(Semantic.Colors.backgroundColorElevated))
        .clipShape(panelShape)
        .overlay(
            panelShape.strokeBorder(Semantic.Colors.subtleOutlineColor, lineWidth: 1)
        )
        .padding(1)
        .environment(\.statusSymbolsOutdated, coordinator.isStale)
        .onAppear {
            coordinator.refresh(reason: .popover)
        }
        .onChange(of: selectedTab) { tab in
            if settings.lastPopoverTab != tab {
                settings.lastPopoverTab = tab
            }
        }
    }

    private var header: some View {
        HStack(spacing: Primitive.Layout.spacingSm) {
            if showsRefreshControls {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(lastUpdatedLabel(at: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Semantic.Colors.textDisabled)
                }
            }

            Spacer(minLength: Primitive.Layout.spacingBase)

            if showsRefreshControls {
                Button {
                    coordinator.refresh(reason: .manual)
                } label: {
                    HStack(spacing: 4) {
                        RefreshIcon(isRefreshing: coordinator.isRefreshing)
                        Text("Refresh")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh now")
                .disabled(coordinator.isRefreshing)
                .foregroundStyle(Semantic.Colors.notBlack)
            }

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Settings")
            .foregroundStyle(Semantic.Colors.notBlack)
        }
        .padding(.horizontal, Primitive.Layout.spacingBase)
        .padding(.vertical, 10)
    }

    private var tabs: some View {
        Picker(selection: $selectedTab) {
            ForEach(MergeRequestListKind.allCases, id: \.self) { kind in
                Text(kind.tabTitle).tag(kind)
            }
        } label: {
            Text("Merge request list")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Primitive.Layout.spacingBase)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if displayedMergeRequests.isEmpty && !settings.hasConfiguredInstance {
            EmptyStateView(
                systemImage: "server.rack",
                title: "Connect GitLab",
                message: "Add a GitLab URL and personal access token to start monitoring the merge requests you’ve authored.",
                actionTitle: "Open Settings",
                action: onOpenSettings
            )
        } else if displayedMergeRequests.isEmpty && coordinator.isRefreshing {
            VStack(spacing: Primitive.Layout.spacingSm) {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching merge requests…")
                    .font(.caption)
                    .foregroundStyle(Semantic.Colors.textDisabled)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .padding()
        } else if displayedMergeRequests.isEmpty {
            if selectedTabLoadFailed, let error = coordinator.lastError {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn’t load merge requests",
                    message: error,
                    actionTitle: "Open Settings",
                    action: onOpenSettings,
                    iconColor: Semantic.Colors.statusDestructive
                )
            } else {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "You’re all clear",
                    message: selectedTab.emptyMessage(showRecentlyMerged: settings.showRecentlyMerged),
                    actionTitle: nil,
                    action: nil,
                    iconColor: Semantic.Colors.statusSuccess
                )
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Primitive.Layout.spacingLg) {
                    ForEach(displayedSections) { section in
                        VStack(alignment: .leading, spacing: Primitive.Layout.spacingSm) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Semantic.Colors.textDisabled)
                                .textCase(.uppercase)
                                .accessibilityAddTraits(.isHeader)

                            VStack(alignment: .leading, spacing: Primitive.Layout.spacingLg) {
                                ForEach(section.rows) { row in
                                    mergeRequestRow(
                                        row.item,
                                        isStacked: row.isStacked,
                                        showsDetails: row.showsDetails
                                    )
                                }
                            }
                        }
                    }

                    if !coordinator.errors.isEmpty {
                        VStack(alignment: .leading, spacing: Primitive.Layout.spacingSm) {
                            ForEach(coordinator.errors) { error in
                                Text("\(error.instanceLabel): \(error.message)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Semantic.Colors.statusDestructive)
                            }
                        }
                    }
                }
                .padding(.horizontal, Primitive.Layout.spacingBase)
                .padding(.vertical, Primitive.Layout.spacingBase)
            }
            .frame(maxHeight: 520)
        }
    }

    /// Refresh and the timestamp stay available once there is something to refresh,
    /// including the sample list shown by the G_DEBUG scheme before a token is saved.
    private var showsRefreshControls: Bool {
        settings.hasConfiguredInstance
            || !coordinator.mergeRequests.isEmpty
            || !coordinator.reviewedMergeRequests.isEmpty
    }

    private var showsTabs: Bool {
        showsRefreshControls
    }

    private var displayedMergeRequests: [MergeRequestItem] {
        switch selectedTab {
        case .authored:
            return coordinator.mergeRequests
        case .requestedReviews:
            return coordinator.reviewedMergeRequests
        }
    }

    private var selectedTabLoadFailed: Bool {
        switch selectedTab {
        case .authored:
            return coordinator.authoredLoadFailed
        case .requestedReviews:
            return coordinator.reviewedLoadFailed
        }
    }

    private var displayedSections: [DisplayedSection] {
        let sections = settings.sortOrder.sectioned(displayedMergeRequests)
        return [
            DisplayedSection(kind: .merged, groups: sections.merged),
            DisplayedSection(kind: .mergeQueue, groups: sections.mergeQueue),
            DisplayedSection(kind: .ready, groups: sections.ready),
            DisplayedSection(kind: .draft, groups: sections.draft)
        ].filter { !$0.rows.isEmpty }
    }

    private func mergeRequestRow(
        _ item: MergeRequestItem,
        isStacked: Bool,
        showsDetails: Bool
    ) -> some View {
        MRRowView(
            item: item,
            showInstanceLabel: showsInstanceLabels,
            titleParsing: settings.titleParsing,
            showThreadBadges: settings.showThreadBadges,
            isStacked: isStacked,
            showsDetails: showsDetails,
            onOpen: {
                openOnInstance(item.webURL, instanceID: item.instanceID)
            },
            onOpenURL: { url in
                openOnInstance(url, instanceID: item.instanceID)
            }
        )
    }

    private var showsInstanceLabels: Bool {
        if settings.instances.count > 1 { return true }
        return Set(displayedMergeRequests.map(\.instanceLabel)).count > 1
    }

    /// Opens a GitLab page in the browser only when it is on that instance's host.
    private func openOnInstance(_ url: URL?, instanceID: UUID) {
        guard let url,
              let instance = settings.instances.first(where: { $0.id == instanceID }),
              instance.allows(url: url) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func lastUpdatedLabel(at now: Date) -> String {
        guard let lastUpdated = coordinator.lastUpdated else {
            return "Never updated"
        }
        let seconds = max(0, Int(now.timeIntervalSince(lastUpdated)))
        if (seconds < 8) {
            return "Updated now"
        }
        return "Updated \(seconds) seconds ago"
    }
}

private struct DisplayedSection: Identifiable {
    enum Kind: String {
        case merged
        case mergeQueue
        case ready
        case draft

        var title: String {
            switch self {
            case .merged: return "Merged"
            case .mergeQueue: return "Merge queue"
            case .ready: return "Ready"
            case .draft: return "Draft"
            }
        }
    }

    let kind: Kind
    let rows: [DisplayedMergeRequest]

    var id: String { kind.rawValue }
    var title: String { kind.title }

    init(kind: Kind, groups: [MergeRequestGroup]) {
        self.kind = kind
        self.rows = groups.flatMap { group in
            [DisplayedMergeRequest(kind: kind, item: group.root, isStacked: false)]
                + group.stacked.map { DisplayedMergeRequest(kind: kind, item: $0, isStacked: true) }
        }
    }
}

private struct DisplayedMergeRequest: Identifiable {
    let kind: DisplayedSection.Kind
    let item: MergeRequestItem
    let isStacked: Bool
    var id: String { "\(kind.rawValue)-\(item.id)" }
    /// Ready parents in Draft are context for the stack, not a second full row.
    var showsDetails: Bool { kind != .draft || item.isDraft }
}

/// Refresh control. The system arrow’s circular stroke sits below the middle of its bounds,
/// so spinning that image around its center makes the arrow orbit. This draws it on a square
/// whose center is the stroke, then turns that square at a constant speed.
private struct RefreshIcon: View {
    let isRefreshing: Bool

    private static let spinPeriod: TimeInterval = 0.8

    @State private var spinStartedAt: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isRefreshing)) { context in
            Image(nsImage: RefreshSymbol.image)
                .renderingMode(.template)
                .rotationEffect(.degrees(spinDegrees(at: context.date)))
                .transaction { $0.disablesAnimations = true }
        }
        .onAppear { updateSpinStart(isRefreshing) }
        .onChange(of: isRefreshing) { refreshing in
            updateSpinStart(refreshing)
        }
    }

    private func updateSpinStart(_ refreshing: Bool) {
        if refreshing {
            if spinStartedAt == nil {
                spinStartedAt = Date()
            }
        } else {
            spinStartedAt = nil
        }
    }

    private func spinDegrees(at date: Date) -> Double {
        guard isRefreshing, let spinStartedAt else { return 0 }
        return date.timeIntervalSince(spinStartedAt) / Self.spinPeriod * 360
    }
}

private enum RefreshSymbol {
    static let side: CGFloat = 18

    static let image: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let symbol = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh"
        )?.withSymbolConfiguration(config) else {
            return NSImage()
        }
        symbol.isTemplate = false

        let boundsCenter = CGPoint(x: symbol.size.width / 2, y: symbol.size.height / 2)
        // 13pt semibold `arrow.clockwise`: stroke center relative to the bounds center (y-up).
        let strokeCenter = CGPoint(x: boundsCenter.x - 0.15, y: boundsCenter.y - 1.55)
        let origin = CGPoint(x: side / 2 - strokeCenter.x, y: side / 2 - strokeCenter.y)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            symbol.draw(in: NSRect(origin: origin, size: symbol.size))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Refresh"
        return image
    }()
}

private struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    var iconColor: Color = Semantic.Colors.buttonPrimaryBackground

    var body: some View {
        VStack(spacing: Primitive.Layout.spacingBase) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .accessibilityHidden(true)

            VStack(spacing: Primitive.Layout.spacingSm) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Semantic.Colors.notBlack)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.callout)
                    .foregroundStyle(Semantic.Colors.textDisabled)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Semantic.Colors.buttonPrimaryBackground)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Primitive.Layout.spacingLg)
        .padding(.vertical, Primitive.Layout.spacingLg)
        .frame(minHeight: 200)
    }
}
