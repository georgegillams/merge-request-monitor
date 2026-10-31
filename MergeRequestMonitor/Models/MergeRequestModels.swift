//
//  MergeRequestModels.swift
//  MergeRequestMonitor
//

import Foundation

enum PipelineStageStatus: String, Codable, Equatable {
    case success
    case paused
    case failed
    case cancelled
    case inProgress
    case created
    case skipped
    case manual
    case unknown

    /// Maps a job or stage status string from GitLab onto the icon set.
    static func fromGitLabStatus(_ status: String?) -> PipelineStageStatus {
        switch (status ?? "").lowercased() {
        case "success", "success_with_warnings", "passed":
            return .success
        case "failed":
            return .failed
        case "running", "preparing":
            return .inProgress
        case "pending", "scheduled", "waiting_for_resource", "waiting_for_callback":
            return .paused
        case "manual":
            return .manual
        case "created":
            return .created
        case "skipped":
            return .skipped
        case "canceled", "cancelled", "canceling":
            return .cancelled
        default:
            return .unknown
        }
    }

    var helpText: String {
        switch self {
        case .success: return "Passed"
        case .paused: return "Paused"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .inProgress: return "In progress"
        case .created: return "Created"
        case .skipped: return "Skipped"
        case .manual: return "Waiting for manual action"
        case .unknown: return "Unknown"
        }
    }
}

struct PipelineJob: Identifiable, Equatable, Codable {
    let id: Int
    let name: String
    let status: PipelineStageStatus
    let webURL: URL?
}

struct PipelineStage: Identifiable, Equatable, Codable {
    var id: String { name }
    let name: String
    let status: PipelineStageStatus
    let jobs: [PipelineJob]

    init(name: String, status: PipelineStageStatus, jobs: [PipelineJob] = []) {
        self.name = name
        self.status = status
        self.jobs = jobs
    }
}

struct ApprovalSummary: Equatable, Codable {
    let approvedBy: [String]
    let approvalsRequired: Int?
    let approvalsLeft: Int?
    let userHasApproved: Bool

    var displayText: String {
        if let required = approvalsRequired, required > 0 {
            let approved = max(0, required - (approvalsLeft ?? max(0, required - approvedBy.count)))
            return "\(min(approved, required))/\(required)"
        }
        if approvedBy.isEmpty {
            return "No approvals"
        }
        return "\(approvedBy.count) approved"
    }
}

/// Resolvable discussion threads on a merge request.
struct ThreadSummary: Equatable, Codable {
    let resolvable: Int
    let resolved: Int

    static let empty = ThreadSummary(resolvable: 0, resolved: 0)

    var hasThreads: Bool { resolvable > 0 }

    var displayText: String {
        "\(resolved) of \(resolvable) threads resolved"
    }
}

/// How the purple merge mark next to approvals should draw, if at all.
enum MergeIndicator: String, Equatable, Codable {
    /// Open, and not on a merge train.
    case none
    /// Currently sitting on a merge train.
    case mergeTrain
    /// Merged recently (shown with a solid mark, without pipeline or approvals).
    case merged

    var tooltip: String {
        switch self {
        case .none: return ""
        case .mergeTrain: return "In a merge train"
        case .merged: return "Merged"
        }
    }
}

struct MergeRequestItem: Identifiable, Equatable, Codable {
    let id: String
    let instanceID: UUID
    let instanceLabel: String
    let projectID: Int
    let iid: Int
    let title: String
    let projectPath: String
    let webURL: URL?
    /// Branch this merge request merges from.
    let sourceBranch: String
    /// Branch this merge request merges into.
    let targetBranch: String
    /// The target project's default branch (`main`, `develop`, …). Empty if unknown.
    let defaultBranch: String
    let stages: [PipelineStage]
    let approvals: ApprovalSummary
    let threads: ThreadSummary
    let mergeIndicator: MergeIndicator
    /// When the merge request was merged, if it is a recently merged entry.
    let mergedAt: Date?
    /// When the merge request was opened. Missing timestamps sort as the oldest.
    let createdAt: Date
    /// When the merge request was last edited. Missing timestamps sort as the oldest.
    let updatedAt: Date

    var isMerged: Bool { mergeIndicator == .merged }

    var isInMergeQueue: Bool { mergeIndicator == .mergeTrain }

    /// GitLab marks a draft by prefixing the title with `Draft:`.
    var isDraft: Bool {
        ParsedMergeRequestTitle.parse(rawTitle: title, parsing: .none).isDraft
    }

    /// Open, not a draft, and not already in the merge queue or merged.
    var isReady: Bool { !isMerged && !isInMergeQueue && !isDraft }
}

/// A top-level merge request and the MRs stacked on it, flattened to one indent.
struct MergeRequestGroup: Identifiable, Equatable {
    let root: MergeRequestItem
    let stacked: [MergeRequestItem]

    var id: String { root.id }
}

/// Popover sections in display order. A mixed stack can appear in more than one.
struct MergeRequestSections: Equatable {
    let merged: [MergeRequestGroup]
    let mergeQueue: [MergeRequestGroup]
    let ready: [MergeRequestGroup]
    let draft: [MergeRequestGroup]
}

/// Which merge request list is shown in the popover.
enum MergeRequestListKind: String, Codable, CaseIterable {
    case authored
    case requestedReviews

    var tabTitle: String {
        switch self {
        case .authored: return "My merge requests"
        case .requestedReviews: return "Requested reviews"
        }
    }

    /// GitLab `scope` query value for this list.
    var gitLabScope: String {
        switch self {
        case .authored: return "created_by_me"
        case .requestedReviews: return "reviews_for_me"
        }
    }

    /// How far back “recently merged” looks for this list.
    var recentlyMergedWindow: TimeInterval {
        TimeInterval(recentlyMergedWindowHours * 60 * 60)
    }

    var recentlyMergedWindowHours: Int {
        switch self {
        case .authored: return 12
        case .requestedReviews: return 4
        }
    }

    func emptyMessage(showRecentlyMerged: Bool) -> String {
        switch self {
        case .authored:
            return showRecentlyMerged
                ? "No open or recently merged merge requests authored by you on the configured GitLab instances."
                : "No open merge requests authored by you on the configured GitLab instances."
        case .requestedReviews:
            return showRecentlyMerged
                ? "No open or recently merged merge requests waiting for your review on the configured GitLab instances."
                : "No open merge requests waiting for your review on the configured GitLab instances."
        }
    }
}

/// Per-tab filters for recently merged and draft merge requests.
struct MergeRequestListFilters: Equatable {
    var showRecentlyMerged: Bool
    var showDrafts: Bool

    static let authoredDefault = MergeRequestListFilters(showRecentlyMerged: true, showDrafts: true)
    static let requestedReviewsDefault = MergeRequestListFilters(showRecentlyMerged: false, showDrafts: false)

    func applying(to items: [MergeRequestItem]) -> [MergeRequestItem] {
        items.filter { item in
            if item.isMerged { return showRecentlyMerged }
            if item.isDraft { return showDrafts }
            return true
        }
    }
}

/// Which list the popover should open on.
enum PopoverTabPreference: String, Codable, CaseIterable {
    case authored
    case requestedReviews
    case lastSelected

    var label: String {
        switch self {
        case .authored: return "My merge requests"
        case .requestedReviews: return "Requested reviews"
        case .lastSelected: return "Last selected"
        }
    }

    func initialTab(lastSelected: MergeRequestListKind) -> MergeRequestListKind {
        switch self {
        case .authored: return .authored
        case .requestedReviews: return .requestedReviews
        case .lastSelected: return lastSelected
        }
    }
}

/// How a merge request title is shortened on the row.
/// Settings shows conventional commits as a switch. Add cases here for other formats.
enum TitleParsing: String, Codable, CaseIterable {
    /// Keep the title, aside from a leading `Draft:` prefix.
    case none
    /// Keep only the description from a `type(context): description` subject.
    case conventionalCommits
}

/// List order for open merge requests. Creation is when it was opened; modified is the last edit.
enum MergeRequestSortOrder: String, Codable, CaseIterable {
    case createdNewestFirst
    case createdOldestFirst
    case modifiedNewestFirst
    case modifiedOldestFirst

    var label: String {
        switch self {
        case .createdNewestFirst: return "Created, newest to oldest"
        case .createdOldestFirst: return "Created, oldest to newest"
        case .modifiedNewestFirst: return "Modified, newest to oldest"
        case .modifiedOldestFirst: return "Modified, oldest to newest"
        }
    }

    /// GitLab `order_by` value for this setting.
    var gitLabOrderBy: String {
        switch self {
        case .createdNewestFirst, .createdOldestFirst: return "created_at"
        case .modifiedNewestFirst, .modifiedOldestFirst: return "updated_at"
        }
    }

    /// GitLab `sort` value for this setting.
    var gitLabSort: String {
        switch self {
        case .createdNewestFirst, .modifiedNewestFirst: return "desc"
        case .createdOldestFirst, .modifiedOldestFirst: return "asc"
        }
    }

    /// Reads the current raw value, and the previous two-option values, which meant creation order.
    static func fromStored(_ rawValue: String) -> MergeRequestSortOrder? {
        switch rawValue {
        case "newestFirst": return .createdNewestFirst
        case "oldestFirst": return .createdOldestFirst
        default: return MergeRequestSortOrder(rawValue: rawValue)
        }
    }

    func ordered(_ items: [MergeRequestItem]) -> [MergeRequestItem] {
        items.sorted { lhs, rhs in
            let left = timestamp(of: lhs)
            let right = timestamp(of: rhs)
            if left != right {
                return newestFirst ? left > right : left < right
            }
            let labelOrder = lhs.instanceLabel.localizedCaseInsensitiveCompare(rhs.instanceLabel)
            if labelOrder != .orderedSame {
                return labelOrder == .orderedAscending
            }
            let pathOrder = lhs.projectPath.localizedCaseInsensitiveCompare(rhs.projectPath)
            if pathOrder != .orderedSame {
                return pathOrder == .orderedAscending
            }
            return newestFirst ? lhs.iid > rhs.iid : lhs.iid < rhs.iid
        }
    }

    /// Groups stacked merge requests under the MR they ultimately land on.
    /// Nested stacks stay at one indent: `root`, then every descendant.
    /// Top-level groups keep `ordered` order of their roots; stacked children
    /// are pulled out of that list and shown under the parent.
    func grouped(_ items: [MergeRequestItem]) -> [MergeRequestGroup] {
        MergeRequestStack.groups(from: items, sortOrder: self)
    }

    /// Merged, then Merge queue, then Ready, then Draft. Mixed stacks are split
    /// so each section keeps only its own MRs; Draft still shows the stack's top-level MR.
    func sectioned(_ items: [MergeRequestItem]) -> MergeRequestSections {
        MergeRequestStack.sections(from: items, sortOrder: self)
    }

    private var newestFirst: Bool {
        switch self {
        case .createdNewestFirst, .modifiedNewestFirst: return true
        case .createdOldestFirst, .modifiedOldestFirst: return false
        }
    }

    private func timestamp(of item: MergeRequestItem) -> Date {
        switch self {
        case .createdNewestFirst, .createdOldestFirst: return item.createdAt
        case .modifiedNewestFirst, .modifiedOldestFirst: return item.mergedAt ?? item.updatedAt
        }
    }
}

/// Stacks MRs whose target branch is another authored MR's source branch in the same project.
/// An MR that targets the project's default branch is always a stack root, even when
/// another MR uses that default branch as its source.
enum MergeRequestStack {
    static func groups(
        from items: [MergeRequestItem],
        sortOrder: MergeRequestSortOrder
    ) -> [MergeRequestGroup] {
        let sorted = sortOrder.ordered(items)
        let parents = ParentIndex(items: sorted)
        return makeGroups(sorted: sorted, parents: parents)
    }

    static func sections(
        from items: [MergeRequestItem],
        sortOrder: MergeRequestSortOrder
    ) -> MergeRequestSections {
        let sorted = sortOrder.ordered(items)
        let parents = ParentIndex(items: sorted)
        let groups = makeGroups(sorted: sorted, parents: parents)

        var merged: [MergeRequestGroup] = []
        var mergeQueue: [MergeRequestGroup] = []
        var ready: [MergeRequestGroup] = []
        var draft: [MergeRequestGroup] = []
        for group in groups {
            merged.append(contentsOf: matchingGroups(from: group, parents: parents) { $0.isMerged })
            mergeQueue.append(contentsOf: matchingGroups(from: group, parents: parents) { $0.isInMergeQueue })
            ready.append(contentsOf: matchingGroups(from: group, parents: parents) { $0.isReady })
            if let draftGroup = draftGroup(from: group) {
                draft.append(draftGroup)
            }
        }
        return MergeRequestSections(
            merged: merged,
            mergeQueue: mergeQueue,
            ready: ready,
            draft: draft
        )
    }

    private static func makeGroups(
        sorted: [MergeRequestItem],
        parents: ParentIndex
    ) -> [MergeRequestGroup] {
        var assigned: Set<String> = []
        var groups: [MergeRequestGroup] = []
        for item in sorted {
            if assigned.contains(item.id) { continue }
            let root = parents.root(of: item)
            // Keep the parent's place in the sorted list. A newer stacked MR
            // must not drag the whole stack to the top ahead of a sibling root.
            if root.id != item.id { continue }
            let stacked = parents.descendants(of: root)
            assigned.insert(root.id)
            stacked.forEach { assigned.insert($0.id) }
            groups.append(MergeRequestGroup(root: root, stacked: stacked))
        }
        return groups
    }

    /// Members of the stack that match, still nested under a matching ancestor.
    /// A non-matching root promotes each matching subtree into its own group.
    private static func matchingGroups(
        from group: MergeRequestGroup,
        parents: ParentIndex,
        matching: (MergeRequestItem) -> Bool
    ) -> [MergeRequestGroup] {
        if matching(group.root) {
            return [MergeRequestGroup(
                root: group.root,
                stacked: parents.descendants(of: group.root, matching: matching)
            )]
        }
        return parents.subgroups(from: group.root, matching: matching)
    }

    /// Open drafts in the stack, under the original top-level MR even when that MR is ready or merged.
    private static func draftGroup(from group: MergeRequestGroup) -> MergeRequestGroup? {
        let stackedDrafts = group.stacked.filter { $0.isDraft && !$0.isMerged && !$0.isInMergeQueue }
        let rootIsOpenDraft = group.root.isDraft && !group.root.isMerged && !group.root.isInMergeQueue
        guard rootIsOpenDraft || !stackedDrafts.isEmpty else { return nil }
        return MergeRequestGroup(root: group.root, stacked: stackedDrafts)
    }

    /// Looks up parent/child links by instance, project, and branch name.
    private struct ParentIndex {
        private struct BranchKey: Hashable {
            let instanceID: UUID
            let projectID: Int
            let branch: String
        }

        private let parentByID: [String: MergeRequestItem]
        private let childrenByParentID: [String: [MergeRequestItem]]
        private let sorted: [MergeRequestItem]

        init(items: [MergeRequestItem]) {
            sorted = items

            var bySource: [BranchKey: [MergeRequestItem]] = [:]
            for item in items {
                guard let branch = Self.normalized(item.sourceBranch) else { continue }
                bySource[BranchKey(instanceID: item.instanceID, projectID: item.projectID, branch: branch), default: []].append(item)
            }

            var parentByID: [String: MergeRequestItem] = [:]
            var childrenByParentID: [String: [MergeRequestItem]] = [:]
            for item in items {
                guard let target = Self.normalized(item.targetBranch) else { continue }
                // Landing on the repo default branch is a top-level MR, not a stack child.
                if let defaultBranch = Self.normalized(item.defaultBranch), target == defaultBranch {
                    continue
                }
                let key = BranchKey(instanceID: item.instanceID, projectID: item.projectID, branch: target)
                guard let parent = bySource[key]?.first(where: { $0.id != item.id }) else { continue }
                parentByID[item.id] = parent
                childrenByParentID[parent.id, default: []].append(item)
            }
            self.parentByID = parentByID
            self.childrenByParentID = childrenByParentID
        }

        func root(of item: MergeRequestItem) -> MergeRequestItem {
            var current = item
            var seen: Set<String> = [item.id]
            while let parent = parentByID[current.id] {
                if seen.contains(parent.id) {
                    return sorted.first { seen.contains($0.id) } ?? current
                }
                seen.insert(parent.id)
                current = parent
            }
            return current
        }

        func descendants(of root: MergeRequestItem) -> [MergeRequestItem] {
            descendants(of: root, matching: { _ in true })
        }

        func descendants(
            of root: MergeRequestItem,
            matching: (MergeRequestItem) -> Bool
        ) -> [MergeRequestItem] {
            var result: [MergeRequestItem] = []
            var visiting: Set<String> = [root.id]
            func walk(_ item: MergeRequestItem) {
                for child in childrenByParentID[item.id] ?? [] {
                    if visiting.contains(child.id) { continue }
                    visiting.insert(child.id)
                    if matching(child) {
                        result.append(child)
                    }
                    walk(child)
                }
            }
            walk(root)
            return result
        }

        /// Matching MRs whose parent chain to `root` does not match, each with its
        /// matching descendants stacked underneath.
        func subgroups(
            from root: MergeRequestItem,
            matching: (MergeRequestItem) -> Bool
        ) -> [MergeRequestGroup] {
            var groups: [MergeRequestGroup] = []
            var visiting: Set<String> = [root.id]
            func walk(_ item: MergeRequestItem) {
                for child in childrenByParentID[item.id] ?? [] {
                    if visiting.contains(child.id) { continue }
                    visiting.insert(child.id)
                    if matching(child) {
                        groups.append(MergeRequestGroup(
                            root: child,
                            stacked: descendants(of: child, matching: matching)
                        ))
                    } else {
                        walk(child)
                    }
                }
            }
            walk(root)
            return groups
        }

        private static func normalized(_ branch: String) -> String? {
            let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

struct ParsedMergeRequestTitle: Equatable {
    let isDraft: Bool
    /// Title with a leading `Draft:` removed. This is the hover tooltip.
    let fullTitle: String
    /// Title drawn on the row.
    let displayTitle: String

    static func parse(rawTitle: String, parsing: TitleParsing) -> ParsedMergeRequestTitle {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let (isDraft, withoutDraft) = stripDraft(trimmed)
        let display: String
        switch parsing {
        case .none:
            display = withoutDraft
        case .conventionalCommits:
            display = conventionalDescription(withoutDraft) ?? withoutDraft
        }
        return ParsedMergeRequestTitle(
            isDraft: isDraft,
            fullTitle: withoutDraft,
            displayTitle: display
        )
    }

    /// GitLab marks a draft by prefixing the title with `Draft:`.
    private static func stripDraft(_ title: String) -> (isDraft: Bool, title: String) {
        let prefix = "draft:"
        guard title.lowercased().hasPrefix(prefix) else {
            return (false, title)
        }
        let rest = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return (true, String(rest))
    }

    /// Description after `type(context):`, or nil when the title is not a conventional subject.
    /// The context in parentheses is optional, and a breaking-change `!` before the colon is allowed.
    private static func conventionalDescription(_ title: String) -> String? {
        var index = title.startIndex
        guard index < title.endIndex, isTypeStart(title[index]) else { return nil }
        index = title.index(after: index)
        while index < title.endIndex, isTypeTail(title[index]) {
            index = title.index(after: index)
        }

        if index < title.endIndex, title[index] == "(" {
            let afterOpen = title.index(after: index)
            guard let close = title[afterOpen...].firstIndex(of: ")"), close != afterOpen else { return nil }
            index = title.index(after: close)
        }
        if index < title.endIndex, title[index] == "!" {
            index = title.index(after: index)
        }
        guard index < title.endIndex, title[index] == ":" else { return nil }
        let afterColon = title.index(after: index)
        guard afterColon < title.endIndex else { return nil }
        guard title[afterColon] == " " || title[afterColon] == "\t" else { return nil }

        let description = title[afterColon...].trimmingCharacters(in: .whitespaces)
        return description.isEmpty ? nil : description
    }

    private static func isTypeStart(_ character: Character) -> Bool {
        ("a"..."z").contains(character)
    }

    private static func isTypeTail(_ character: Character) -> Bool {
        isTypeStart(character) || ("0"..."9").contains(character) || character == "-"
    }
}

struct GitLabInstanceConfig: Identifiable, Equatable, Codable {
    var id: UUID
    var label: String
    var baseURL: String

    init(id: UUID = UUID(), label: String = "", baseURL: String = "https://gitlab.com") {
        self.id = id
        self.label = label
        self.baseURL = baseURL
    }

    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: normalizedBaseURL)?.host, !host.isEmpty {
            return host
        }
        return "GitLab"
    }

    var normalizedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.isEmpty {
            return "https://gitlab.com"
        }
        if !value.lowercased().hasPrefix("http://"), !value.lowercased().hasPrefix("https://") {
            value = "https://\(value)"
        }
        return value
    }

    /// True when `url` is an http(s) page on this instance's host.
    func allows(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let allowed = URL(string: normalizedBaseURL)?.host?.lowercased(),
              let host = url.host?.lowercased(),
              !allowed.isEmpty else {
            return false
        }
        return host == allowed
    }
}
