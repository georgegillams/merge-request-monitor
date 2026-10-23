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
    @Published private(set) var errors: [InstanceError] = []
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

    var lastError: String? {
        errors.first?.message
    }

    init(settings: AppSettings) {
        gDebugPrint("RefreshCoordinator.init")
        self.settings = settings
        settingsCancellable = settings.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
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
        refreshTask?.cancel()
        refreshTask = Task { await self.performRefresh() }
    }

    enum RefreshReason {
        case launch, timer, wake, manual, popover
    }

    @MainActor
    private func applyResults(
        collected: [MergeRequestItem],
        collectedErrors: [InstanceError],
        connectedInstanceIDs: Set<UUID>
    ) {
        mergeRequests = settings.sortOrder.ordered(collected)
        errors = collectedErrors
        self.connectedInstanceIDs = connectedInstanceIDs
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
            isStale = !mergeRequests.isEmpty
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
            gDebugPrint("RefreshCoordinator using \(fixtures.count) mock merge requests")
            await applyResults(
                collected: fixtures,
                collectedErrors: DebugMergeRequestFixtures.errors,
                connectedInstanceIDs: Set(fixtures.map(\.instanceID))
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
                errors = []
                connectedInstanceIDs = []
                markUpdated()
                isRefreshing = false
            }
            return
        }

        var collected: [MergeRequestItem] = []
        var collectedErrors: [InstanceError] = []
        var connectedIDs: Set<UUID> = []

        await withTaskGroup(of: Result<(UUID, [MergeRequestItem]), InstanceError>.self) { group in
            for (instance, lookup) in targets {
                let client = self.client
                group.addTask {
                    let token: String
                    switch lookup {
                    case .missing, .locked:
                        return .failure(
                            InstanceError(
                                id: instance.id,
                                instanceLabel: instance.displayLabel,
                                message: "Missing bearer token",
                                kind: .missingCredentials
                            )
                        )
                    case .value(let stored):
                        token = stored
                    }
                    do {
                        let mrs = try await client.fetchAuthoredMergeRequests(
                            instance: instance,
                            token: token,
                            sortOrder: sortOrder,
                            includeRecentlyMerged: showRecentlyMerged
                        )
                        return .success((instance.id, mrs))
                    } catch {
                        return .failure(
                            InstanceError(
                                id: instance.id,
                                instanceLabel: instance.displayLabel,
                                message: error.localizedDescription
                            )
                        )
                    }
                }
            }

            for await result in group {
                if Task.isCancelled { return }
                switch result {
                case .success(let (instanceID, mrs)):
                    connectedIDs.insert(instanceID)
                    collected.append(contentsOf: mrs)
                case .failure(let error):
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
            collectedErrors: collectedErrors,
            connectedInstanceIDs: connectedIDs
        )
    }
}
