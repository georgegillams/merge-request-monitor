//
//  RefreshCoordinator.swift
//  MergeRequestMonitor
//

import Foundation
import Combine
import AppKit

struct StoredTokenExpiry: Equatable {
    let tokenFingerprint: Int
    /// Nil when the token does not expire.
    let expiresAt: Date?
}

struct TokenExpiryPresentation: Equatable {
    let text: String
    let isWarning: Bool
}

struct ExpiringTokenBanner: Identifiable, Equatable {
    let id: UUID
    let message: String
    let expiresAt: Date
}

struct InstanceError: Identifiable, Equatable, LocalizedError {
    enum Kind: Equatable {
        /// URL or token was missing, so no request was made.
        case missingCredentials
        /// A request was made and failed.
        case fetchFailed
    }

    let id: UUID
    let instanceLabel: String
    let message: String
    let kind: Kind

    init(id: UUID, instanceLabel: String, message: String, kind: Kind = .fetchFailed) {
        self.id = id
        self.instanceLabel = instanceLabel
        self.message = message
        self.kind = kind
    }

    var errorDescription: String? { message }
}

final class RefreshCoordinator: ObservableObject {
    /// Status marks fade once the newest fetch is older than this.
    static let staleThreshold: TimeInterval = 60 // 1 minute
    static let pollInterval: TimeInterval = 5 * 60 // 5 minutes

    @Published private(set) var mergeRequests: [MergeRequestItem] = []
    @Published private(set) var reviewedMergeRequests: [MergeRequestItem] = []
    /// Combined instance errors from both lists (for Settings connection badges).
    @Published private(set) var errors: [InstanceError] = []
    @Published private(set) var authoredErrors: [InstanceError] = []
    @Published private(set) var reviewedErrors: [InstanceError] = []
    /// True when every instance failed to load authored merge requests.
    @Published private(set) var authoredLoadFailed = false
    /// True when every instance failed to load other merge requests.
    @Published private(set) var reviewedLoadFailed = false
    /// Instances whose most recent fetch succeeded for either list.
    @Published private(set) var connectedInstanceIDs: Set<UUID> = []
    @Published private(set) var authoredLastUpdated: Date?
    @Published private(set) var reviewedLastUpdated: Date?
    @Published private(set) var isAuthoredRefreshing = false
    @Published private(set) var isReviewedRefreshing = false
    @Published private(set) var isAuthoredStale = false
    @Published private(set) var isReviewedStale = false
    /// Last successful expiry lookup for each instance, keyed by instance id.
    @Published private(set) var tokenExpiries: [UUID: StoredTokenExpiry] = [:]

    private let settings: AppSettings
    private let client = GitLabAPIClient()
    private var pollTimer: Timer?
    private var authoredStaleTimer: Timer?
    private var reviewedStaleTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var settingsCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var authoredConnectedIDs: Set<UUID> = []
    private var reviewedConnectedIDs: Set<UUID> = []
    /// Last settings snapshot that actually triggered a GitLab fetch.
    /// Tab, title-parsing, and similar display-only changes must not refetch.
    private var lastFetchTrigger: FetchTrigger?

    var isRefreshing: Bool {
        isAuthoredRefreshing || isReviewedRefreshing
    }

    var lastUpdated: Date? {
        [authoredLastUpdated, reviewedLastUpdated].compactMap { $0 }.max()
    }

    var isStale: Bool {
        isAuthoredStale || isReviewedStale
    }

    var lastError: String? {
        errors.first?.message
    }

    func isRefreshing(for kind: MergeRequestListKind) -> Bool {
        switch kind {
        case .authored: return isAuthoredRefreshing
        case .requestedReviews: return isReviewedRefreshing
        }
    }

    func isStale(for kind: MergeRequestListKind) -> Bool {
        switch kind {
        case .authored: return isAuthoredStale
        case .requestedReviews: return isReviewedStale
        }
    }

    func lastUpdated(for kind: MergeRequestListKind) -> Date? {
        switch kind {
        case .authored: return authoredLastUpdated
        case .requestedReviews: return reviewedLastUpdated
        }
    }

    func errors(for kind: MergeRequestListKind) -> [InstanceError] {
        switch kind {
        case .authored: return authoredErrors
        case .requestedReviews: return reviewedErrors
        }
    }

    init(settings: AppSettings) {
        gDebugPrint("RefreshCoordinator.init")
        self.settings = settings
        settingsCancellable = settings.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let trigger = self.makeFetchTrigger()
                guard trigger != self.lastFetchTrigger else { return }
                self.refresh()
            }
    }

    func start() {
        gDebugPrint("RefreshCoordinator.start")
        stop()
        refresh()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        authoredStaleTimer?.invalidate()
        authoredStaleTimer = nil
        reviewedStaleTimer?.invalidate()
        reviewedStaleTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh(reason: RefreshReason = .manual) {
        _ = reason
        lastFetchTrigger = makeFetchTrigger()
        refreshTask?.cancel()
        refreshTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.refreshAuthored() }
                group.addTask { await self.refreshReviewed() }
                group.addTask { await self.refreshTokenExpiries() }
            }
        }
    }

    /// Settings copy for one instance. Nil until a lookup has succeeded for the current token.
    func tokenExpiryPresentation(for instanceID: UUID, at now: Date) -> TokenExpiryPresentation? {
        guard let record = matchingTokenExpiry(for: instanceID) else { return nil }
        let warning = record.expiresAt.map {
            GitLabTokenExpiry.isWithinWarningWindow(expiresAt: $0, now: now)
        } ?? false
        return TokenExpiryPresentation(
            text: GitLabTokenExpiry.timeLeftLabel(expiresAt: record.expiresAt, now: now),
            isWarning: warning
        )
    }

    /// Tokens that expire within the next 7 days, soonest first. Includes tokens that already expired.
    func expiringTokenBanners(at now: Date) -> [ExpiringTokenBanner] {
        settings.instances.compactMap { instance -> ExpiringTokenBanner? in
            guard let record = matchingTokenExpiry(for: instance.id),
                  let expiresAt = record.expiresAt,
                  GitLabTokenExpiry.isWithinWarningWindow(expiresAt: expiresAt, now: now) else {
                return nil
            }
            return ExpiringTokenBanner(
                id: instance.id,
                message: GitLabTokenExpiry.bannerMessage(
                    instanceLabel: instance.displayLabel,
                    expiresAt: expiresAt,
                    now: now
                ),
                expiresAt: expiresAt
            )
        }
        .sorted { $0.expiresAt < $1.expiresAt }
    }

    private func matchingTokenExpiry(for instanceID: UUID) -> StoredTokenExpiry? {
        guard let record = tokenExpiries[instanceID] else { return nil }
        let fingerprint = Self.tokenFingerprint(settings.lookupToken(for: instanceID))
        guard record.tokenFingerprint == fingerprint else { return nil }
        return record
    }

    enum RefreshReason {
        case launch, timer, wake, manual, popover
    }

    private func refreshAuthored() async {
        let (targets, sortOrder, showRecentlyMerged) = await MainActor.run {
            (
                settings.instances.map { instance in
                    (instance, settings.lookupToken(for: instance.id))
                },
                settings.sortOrder,
                settings.authoredFilters.showRecentlyMerged
            )
        }

        #if DEBUG
        if isGDebugScheme {
            let fixtures = DebugMergeRequestFixtures.mergeRequests.filter {
                showRecentlyMerged || !$0.isMerged
            }
            gDebugPrint("RefreshCoordinator using \(fixtures.count) authored mock merge requests")
            await applyAuthoredResults(
                items: fixtures,
                errors: DebugMergeRequestFixtures.errors,
                connectedIDs: Set(fixtures.map(\.instanceID)),
                loadFailed: false
            )
            return
        }
        #endif

        if targets.contains(where: { if case .locked = $0.1 { return true }; return false }) {
            return
        }

        await MainActor.run { isAuthoredRefreshing = true }

        guard !targets.isEmpty else {
            await applyAuthoredResults(items: [], errors: [], connectedIDs: [], loadFailed: false)
            return
        }

        var collected: [MergeRequestItem] = []
        var collectedErrors: [InstanceError] = []
        var connectedIDs: Set<UUID> = []
        var succeeded = false

        await withTaskGroup(of: ListFetch.self) { group in
            for (instance, lookup) in targets {
                let client = self.client
                group.addTask {
                    await Self.fetchListForInstance(
                        instance: instance,
                        lookup: lookup,
                        client: client,
                        sortOrder: sortOrder,
                        showRecentlyMerged: showRecentlyMerged,
                        kind: .authored,
                        otherSources: .default
                    )
                }
            }
            for await result in group {
                if Task.isCancelled { break }
                collected.append(contentsOf: result.items)
                if result.succeeded {
                    succeeded = true
                    connectedIDs.insert(result.instanceID)
                }
                if let error = result.error {
                    collectedErrors.append(error)
                }
            }
        }

        if Task.isCancelled {
            await MainActor.run { isAuthoredRefreshing = false }
            return
        }

        await applyAuthoredResults(
            items: collected,
            errors: collectedErrors,
            connectedIDs: connectedIDs,
            loadFailed: !succeeded
        )
    }

    private func refreshReviewed() async {
        let (targets, sortOrder, showRecentlyMerged, otherSources) = await MainActor.run {
            (
                settings.instances.map { instance in
                    (instance, settings.lookupToken(for: instance.id))
                },
                settings.sortOrder,
                settings.requestedReviewFilters.showRecentlyMerged,
                settings.otherSources
            )
        }

        #if DEBUG
        if isGDebugScheme {
            let fixtures = DebugMergeRequestFixtures.reviewedMergeRequests.filter {
                showRecentlyMerged || !$0.isMerged
            }
            gDebugPrint("RefreshCoordinator using \(fixtures.count) other mock merge requests")
            await applyReviewedResults(
                items: fixtures,
                errors: [],
                connectedIDs: Set(fixtures.map(\.instanceID)),
                loadFailed: false
            )
            return
        }
        #endif

        if targets.contains(where: { if case .locked = $0.1 { return true }; return false }) {
            return
        }

        await MainActor.run { isReviewedRefreshing = true }

        guard !targets.isEmpty else {
            await applyReviewedResults(items: [], errors: [], connectedIDs: [], loadFailed: false)
            return
        }

        var collected: [MergeRequestItem] = []
        var collectedErrors: [InstanceError] = []
        var connectedIDs: Set<UUID> = []
        var succeeded = false

        await withTaskGroup(of: ListFetch.self) { group in
            for (instance, lookup) in targets {
                let client = self.client
                group.addTask {
                    await Self.fetchListForInstance(
                        instance: instance,
                        lookup: lookup,
                        client: client,
                        sortOrder: sortOrder,
                        showRecentlyMerged: showRecentlyMerged,
                        kind: .requestedReviews,
                        otherSources: otherSources
                    )
                }
            }
            for await result in group {
                if Task.isCancelled { break }
                collected.append(contentsOf: result.items)
                if result.succeeded {
                    succeeded = true
                    connectedIDs.insert(result.instanceID)
                }
                if let error = result.error {
                    collectedErrors.append(error)
                }
            }
        }

        if Task.isCancelled {
            await MainActor.run { isReviewedRefreshing = false }
            return
        }

        await applyReviewedResults(
            items: collected,
            errors: collectedErrors,
            connectedIDs: connectedIDs,
            loadFailed: !succeeded
        )
    }

    @MainActor
    private func applyAuthoredResults(
        items: [MergeRequestItem],
        errors: [InstanceError],
        connectedIDs: Set<UUID>,
        loadFailed: Bool
    ) {
        mergeRequests = settings.sortOrder.ordered(items)
        authoredErrors = errors
        authoredLoadFailed = loadFailed
        authoredConnectedIDs = connectedIDs
        republishSharedState()
        // Drop any authored MRs that also landed in Other after this faster list finished.
        refilterReviewedExcludingAuthored()
        markAuthoredUpdated()
        isAuthoredRefreshing = false
    }

    @MainActor
    private func applyReviewedResults(
        items: [MergeRequestItem],
        errors: [InstanceError],
        connectedIDs: Set<UUID>,
        loadFailed: Bool
    ) {
        let authoredIDs = Set(mergeRequests.map(\.id))
        reviewedMergeRequests = settings.sortOrder.ordered(
            items.filter { !authoredIDs.contains($0.id) }
        )
        reviewedErrors = errors
        reviewedLoadFailed = loadFailed
        reviewedConnectedIDs = connectedIDs
        republishSharedState()
        markReviewedUpdated()
        isReviewedRefreshing = false
    }

    @MainActor
    private func refilterReviewedExcludingAuthored() {
        let authoredIDs = Set(mergeRequests.map(\.id))
        let filtered = reviewedMergeRequests.filter { !authoredIDs.contains($0.id) }
        if filtered.count != reviewedMergeRequests.count {
            reviewedMergeRequests = filtered
        }
    }

    @MainActor
    private func republishSharedState() {
        connectedInstanceIDs = authoredConnectedIDs.union(reviewedConnectedIDs)
        errors = authoredErrors + reviewedErrors.filter { reviewed in
            !authoredErrors.contains(where: { $0.id == reviewed.id })
        }
    }

    private func markAuthoredUpdated() {
        authoredLastUpdated = Date()
        refreshAuthoredStaleState()
    }

    private func markReviewedUpdated() {
        reviewedLastUpdated = Date()
        refreshReviewedStaleState()
    }

    private func refreshAuthoredStaleState() {
        authoredStaleTimer?.invalidate()
        authoredStaleTimer = nil

        guard let authoredLastUpdated else {
            isAuthoredStale = !mergeRequests.isEmpty
            return
        }

        let remaining = Self.staleThreshold - Date().timeIntervalSince(authoredLastUpdated)
        guard remaining > 0 else {
            isAuthoredStale = true
            return
        }

        isAuthoredStale = false
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            self?.refreshAuthoredStaleState()
        }
        RunLoop.main.add(timer, forMode: .common)
        authoredStaleTimer = timer
    }

    private func refreshReviewedStaleState() {
        reviewedStaleTimer?.invalidate()
        reviewedStaleTimer = nil

        guard let reviewedLastUpdated else {
            isReviewedStale = !reviewedMergeRequests.isEmpty
            return
        }

        let remaining = Self.staleThreshold - Date().timeIntervalSince(reviewedLastUpdated)
        guard remaining > 0 else {
            isReviewedStale = true
            return
        }

        isReviewedStale = false
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            self?.refreshReviewedStaleState()
        }
        RunLoop.main.add(timer, forMode: .common)
        reviewedStaleTimer = timer
    }

    private func refreshTokenExpiries() async {
        let targets: [(instance: GitLabInstanceConfig, lookup: TokenLookup, fingerprint: Int)] = await MainActor.run {
            settings.instances.map { instance in
                let lookup = settings.lookupToken(for: instance.id)
                return (instance, lookup, Self.tokenFingerprint(lookup))
            }
        }

        #if DEBUG
        if isGDebugScheme {
            await applyDebugTokenExpiries(targets)
            return
        }
        #endif

        if targets.contains(where: { if case .locked = $0.lookup { return true }; return false }) {
            return
        }

        var fetched: [UUID: StoredTokenExpiry] = [:]
        await withTaskGroup(of: (UUID, StoredTokenExpiry)?.self) { group in
            for target in targets {
                guard case .value(let token) = target.lookup else { continue }
                let client = self.client
                let baseURL = target.instance.normalizedBaseURL
                let fingerprint = target.fingerprint
                group.addTask {
                    do {
                        let expiresAt = try await client.fetchPersonalAccessTokenExpiry(
                            baseURL: baseURL,
                            token: token
                        )
                        return (target.instance.id, StoredTokenExpiry(tokenFingerprint: fingerprint, expiresAt: expiresAt))
                    } catch {
                        gDebugPrint(
                            "token expiry lookup failed for \(target.instance.displayLabel):",
                            error.localizedDescription
                        )
                        return nil
                    }
                }
            }
            for await result in group {
                if Task.isCancelled { break }
                if let (id, record) = result {
                    fetched[id] = record
                }
            }
        }

        if Task.isCancelled { return }

        let fetchedExpiries = fetched
        await MainActor.run {
            guard !Task.isCancelled else { return }
            var next: [UUID: StoredTokenExpiry] = [:]
            for target in targets {
                guard case .value = target.lookup else { continue }
                if let fresh = fetchedExpiries[target.instance.id] {
                    next[target.instance.id] = fresh
                } else if let previous = tokenExpiries[target.instance.id],
                          previous.tokenFingerprint == target.fingerprint {
                    next[target.instance.id] = previous
                }
            }
            tokenExpiries = next
        }
    }

    #if DEBUG
    /// G_DEBUG does not call GitLab for token expiry. The first configured token
    /// expires in 4 days, so the warning banner and highlight show. A second
    /// configured token expires in 12 days and stays outside that window.
    private func applyDebugTokenExpiries(
        _ targets: [(instance: GitLabInstanceConfig, lookup: TokenLookup, fingerprint: Int)]
    ) async {
        let day: TimeInterval = 24 * 60 * 60
        let daysUntilExpiry = [4, 12]
        let now = Date()
        await MainActor.run {
            guard !Task.isCancelled else { return }
            var next: [UUID: StoredTokenExpiry] = [:]
            var configuredIndex = 0
            for target in targets where target.lookup != .missing {
                guard configuredIndex < daysUntilExpiry.count else { break }
                next[target.instance.id] = StoredTokenExpiry(
                    tokenFingerprint: target.fingerprint,
                    expiresAt: now.addingTimeInterval(TimeInterval(daysUntilExpiry[configuredIndex]) * day)
                )
                configuredIndex += 1
            }
            tokenExpiries = next
            gDebugPrint("RefreshCoordinator mocked token expiry for \(next.count) instance(s)")
        }
    }
    #endif

    private struct ListFetch {
        let instanceID: UUID
        let items: [MergeRequestItem]
        let error: InstanceError?
        let succeeded: Bool
    }

    private static func fetchListForInstance(
        instance: GitLabInstanceConfig,
        lookup: TokenLookup,
        client: GitLabAPIClient,
        sortOrder: MergeRequestSortOrder,
        showRecentlyMerged: Bool,
        kind: MergeRequestListKind,
        otherSources: OtherMergeRequestSources
    ) async -> ListFetch {
        let token: String
        switch lookup {
        case .missing, .locked:
            return ListFetch(
                instanceID: instance.id,
                items: [],
                error: InstanceError(
                    id: instance.id,
                    instanceLabel: instance.displayLabel,
                    message: "Missing bearer token",
                    kind: .missingCredentials
                ),
                succeeded: false
            )
        case .value(let stored):
            token = stored
        }

        do {
            let items = try await client.fetchMergeRequests(
                instance: instance,
                token: token,
                sortOrder: sortOrder,
                includeRecentlyMerged: showRecentlyMerged,
                kind: kind,
                otherSources: otherSources
            )
            return ListFetch(
                instanceID: instance.id,
                items: items,
                error: nil,
                succeeded: true
            )
        } catch {
            return ListFetch(
                instanceID: instance.id,
                items: [],
                error: InstanceError(
                    id: instance.id,
                    instanceLabel: instance.displayLabel,
                    message: error.localizedDescription
                ),
                succeeded: false
            )
        }
    }

    /// Values that require a GitLab refetch. Display-only settings are omitted.
    private struct FetchTrigger: Equatable {
        struct Instance: Equatable {
            let id: UUID
            let url: String
            let label: String
            let tokenFingerprint: Int
        }

        let instances: [Instance]
        let sortOrder: MergeRequestSortOrder
        let authoredShowRecentlyMerged: Bool
        let requestedShowRecentlyMerged: Bool
        let otherSources: OtherMergeRequestSources
    }

    private func makeFetchTrigger() -> FetchTrigger {
        FetchTrigger(
            instances: settings.instances.map { instance in
                FetchTrigger.Instance(
                    id: instance.id,
                    url: instance.baseURL,
                    label: instance.label,
                    tokenFingerprint: Self.tokenFingerprint(settings.lookupToken(for: instance.id))
                )
            },
            sortOrder: settings.sortOrder,
            authoredShowRecentlyMerged: settings.authoredFilters.showRecentlyMerged,
            requestedShowRecentlyMerged: settings.requestedReviewFilters.showRecentlyMerged,
            otherSources: settings.otherSources
        )
    }

    private static func tokenFingerprint(_ lookup: TokenLookup) -> Int {
        switch lookup {
        case .missing:
            return 0
        case .locked:
            return 1
        case .value(let token):
            var hasher = Hasher()
            hasher.combine(token)
            return hasher.finalize()
        }
    }
}
