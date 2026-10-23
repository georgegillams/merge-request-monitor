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
