//
//  RefreshCoordinator.swift
//  MergeRequestMonitor
//

import Foundation
import Combine
import AppKit

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
    @Published private(set) var errors: [InstanceError] = []
    /// True when every instance failed to load authored merge requests.
    @Published private(set) var authoredLoadFailed = false
    /// True when every instance failed to load requested reviews.
    @Published private(set) var reviewedLoadFailed = false
    /// Instances whose most recent fetch succeeded. Empty until that result arrives,
    /// so a first attempt is not shown as connected while it is still in flight.
    @Published private(set) var connectedInstanceIDs: Set<UUID> = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    /// True once `lastUpdated` is more than `staleThreshold` ago, so status marks can fade
    /// without waiting for another fetch to republish.
    @Published private(set) var isStale = false

    private let settings: AppSettings
    private let client = GitLabAPIClient()
    private var pollTimer: Timer?
    private var staleTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var settingsCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    /// Last settings snapshot that actually triggered a GitLab fetch.
    /// Tab, title-parsing, and similar display-only changes must not refetch.
    private var lastFetchTrigger: FetchTrigger?

    var lastError: String? {
        errors.first?.message
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
        staleTimer?.invalidate()
        staleTimer = nil
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
        refreshTask = Task { await self.performRefresh() }
    }

    enum RefreshReason {
        case launch, timer, wake, manual, popover
    }

    @MainActor
    private func applyResults(
        collected: [MergeRequestItem],
        reviewed: [MergeRequestItem],
        collectedErrors: [InstanceError],
        connectedInstanceIDs: Set<UUID>,
        authoredLoadFailed: Bool,
        reviewedLoadFailed: Bool
    ) {
        mergeRequests = settings.sortOrder.ordered(collected)
        reviewedMergeRequests = settings.sortOrder.ordered(reviewed)
        errors = collectedErrors
        self.connectedInstanceIDs = connectedInstanceIDs
        self.authoredLoadFailed = authoredLoadFailed
        self.reviewedLoadFailed = reviewedLoadFailed
        markUpdated()
        isRefreshing = false
    }

    /// Records a completed fetch and fades status marks once that snapshot is over a minute old.
    private func markUpdated() {
        lastUpdated = Date()
        refreshStaleState()
    }

    private func refreshStaleState() {
        staleTimer?.invalidate()
        staleTimer = nil

        guard let lastUpdated else {
            isStale = !mergeRequests.isEmpty || !reviewedMergeRequests.isEmpty
            return
        }

        let remaining = Self.staleThreshold - Date().timeIntervalSince(lastUpdated)
        guard remaining > 0 else {
            isStale = true
            return
        }

        isStale = false
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            self?.refreshStaleState()
        }
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    private func performRefresh() async {
        let (targets, sortOrder, showRecentlyMerged) = await MainActor.run {
            (
                settings.instances.map { instance in
                    (instance, settings.lookupToken(for: instance.id))
                },
                settings.sortOrder,
                settings.showRecentlyMerged
            )
        }

        #if DEBUG
        if isGDebugScheme {
            let fixtures = DebugMergeRequestFixtures.mergeRequests.filter {
                showRecentlyMerged || !$0.isMerged
            }
            let reviewedFixtures = DebugMergeRequestFixtures.reviewedMergeRequests.filter {
                showRecentlyMerged || !$0.isMerged
            }
            gDebugPrint(
                "RefreshCoordinator using \(fixtures.count) authored and \(reviewedFixtures.count) review mock merge requests"
            )
            await applyResults(
                collected: fixtures,
                reviewed: reviewedFixtures,
                collectedErrors: DebugMergeRequestFixtures.errors,
                connectedInstanceIDs: Set(
                    (fixtures + reviewedFixtures).map(\.instanceID)
                ),
                authoredLoadFailed: false,
                reviewedLoadFailed: false
            )
            return
        }
        #endif

        // While the Mac is locked the token stays sealed. Keep the last result
        // instead of treating that as a missing credential.
        if targets.contains(where: { if case .locked = $0.1 { return true }; return false }) {
            return
        }

        await MainActor.run { isRefreshing = true }

        guard !targets.isEmpty else {
            await MainActor.run {
                mergeRequests = []
                reviewedMergeRequests = []
                errors = []
                connectedInstanceIDs = []
                authoredLoadFailed = false
                reviewedLoadFailed = false
                markUpdated()
                isRefreshing = false
            }
            return
        }

        var collected: [MergeRequestItem] = []
        var reviewedCollected: [MergeRequestItem] = []
        var collectedErrors: [InstanceError] = []
        var connectedIDs: Set<UUID> = []
        var authoredSucceeded = false
        var reviewedSucceeded = false

        await withTaskGroup(of: InstanceFetch.self) { group in
            for (instance, lookup) in targets {
                let client = self.client
                group.addTask {
                    await Self.fetchInstance(
                        instance: instance,
                        lookup: lookup,
                        client: client,
                        sortOrder: sortOrder,
                        showRecentlyMerged: showRecentlyMerged
                    )
                }
            }

            for await result in group {
                if Task.isCancelled { break }
                collected.append(contentsOf: result.authored)
                reviewedCollected.append(contentsOf: result.reviewed)
                if result.connected {
                    connectedIDs.insert(result.instanceID)
                }
                if result.authoredSucceeded {
                    authoredSucceeded = true
                }
                if result.reviewedSucceeded {
                    reviewedSucceeded = true
                }
                if let error = result.error {
                    collectedErrors.append(error)
                }
            }
        }

        if Task.isCancelled {
            await MainActor.run { isRefreshing = false }
            return
        }

        await applyResults(
            collected: collected,
            reviewed: reviewedCollected,
            collectedErrors: collectedErrors,
            connectedInstanceIDs: connectedIDs,
            authoredLoadFailed: !authoredSucceeded,
            reviewedLoadFailed: !reviewedSucceeded
        )
    }

    private struct InstanceFetch {
        let instanceID: UUID
        let authored: [MergeRequestItem]
        let reviewed: [MergeRequestItem]
        let error: InstanceError?
        let connected: Bool
        let authoredSucceeded: Bool
        let reviewedSucceeded: Bool
    }

    private static func fetchInstance(
        instance: GitLabInstanceConfig,
        lookup: TokenLookup,
        client: GitLabAPIClient,
        sortOrder: MergeRequestSortOrder,
        showRecentlyMerged: Bool
    ) async -> InstanceFetch {
        let token: String
        switch lookup {
        case .missing, .locked:
            return InstanceFetch(
                instanceID: instance.id,
                authored: [],
                reviewed: [],
                error: InstanceError(
                    id: instance.id,
                    instanceLabel: instance.displayLabel,
                    message: "Missing bearer token",
                    kind: .missingCredentials
                ),
                connected: false,
                authoredSucceeded: false,
                reviewedSucceeded: false
            )
        case .value(let stored):
            token = stored
        }

        async let authoredAttempt = fetchList(
            client: client,
            instance: instance,
            token: token,
            sortOrder: sortOrder,
            showRecentlyMerged: showRecentlyMerged,
            kind: .authored
        )
        async let reviewedAttempt = fetchList(
            client: client,
            instance: instance,
            token: token,
            sortOrder: sortOrder,
            showRecentlyMerged: showRecentlyMerged,
            kind: .requestedReviews
        )
        let authored = await authoredAttempt
        let reviewed = await reviewedAttempt

        switch (authored, reviewed) {
        case (.success(let authoredMRs), .success(let reviewedMRs)):
            return InstanceFetch(
                instanceID: instance.id,
                authored: authoredMRs,
                reviewed: reviewedMRs,
                error: nil,
                connected: true,
                authoredSucceeded: true,
                reviewedSucceeded: true
            )
        case (.success(let authoredMRs), .failure(let error)):
            return InstanceFetch(
                instanceID: instance.id,
                authored: authoredMRs,
                reviewed: [],
                error: InstanceError(
                    id: instance.id,
                    instanceLabel: instance.displayLabel,
                    message: error.localizedDescription
                ),
                connected: true,
                authoredSucceeded: true,
                reviewedSucceeded: false
            )
        case (.failure(let error), .success(let reviewedMRs)):
            return InstanceFetch(
                instanceID: instance.id,
                authored: [],
                reviewed: reviewedMRs,
                error: InstanceError(
                    id: instance.id,
                    instanceLabel: instance.displayLabel,
                    message: error.localizedDescription
                ),
                connected: true,
                authoredSucceeded: false,
                reviewedSucceeded: true
            )
        case (.failure(let error), .failure):
            return InstanceFetch(
                instanceID: instance.id,
                authored: [],
                reviewed: [],
                error: InstanceError(
                    id: instance.id,
                    instanceLabel: instance.displayLabel,
                    message: error.localizedDescription
                ),
                connected: false,
                authoredSucceeded: false,
                reviewedSucceeded: false
            )
        }
    }

    private static func fetchList(
        client: GitLabAPIClient,
        instance: GitLabInstanceConfig,
        token: String,
        sortOrder: MergeRequestSortOrder,
        showRecentlyMerged: Bool,
        kind: MergeRequestListKind
    ) async -> Result<[MergeRequestItem], Error> {
        do {
            let items = try await client.fetchMergeRequests(
                instance: instance,
                token: token,
                sortOrder: sortOrder,
                includeRecentlyMerged: showRecentlyMerged,
                kind: kind
            )
            return .success(items)
        } catch {
            return .failure(error)
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
        let showRecentlyMerged: Bool
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
            showRecentlyMerged: settings.showRecentlyMerged
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
