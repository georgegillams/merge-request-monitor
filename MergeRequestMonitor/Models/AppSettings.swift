//
//  AppSettings.swift
//  MergeRequestMonitor
//

import Foundation
import Combine

final class AppSettings: ObservableObject {
    @Published private(set) var instances: [GitLabInstanceConfig]
    @Published var titleParsing: TitleParsing {
        didSet {
            guard titleParsing != oldValue else { return }
            UserDefaults.standard.set(titleParsing.rawValue, forKey: Self.titleParsingKey)
        }
    }
    @Published var sortOrder: MergeRequestSortOrder {
        didSet {
            guard sortOrder != oldValue else { return }
            UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortOrderKey)
        }
    }
    /// When false, discussion thread badges are omitted from merge request rows.
    @Published var showThreadBadges: Bool {
        didSet {
            guard showThreadBadges != oldValue else { return }
            UserDefaults.standard.set(showThreadBadges, forKey: Self.showThreadBadgesKey)
        }
    }
    /// When false, merge requests merged in the last 12 hours are omitted.
    @Published var showRecentlyMerged: Bool {
        didSet {
            guard showRecentlyMerged != oldValue else { return }
            UserDefaults.standard.set(showRecentlyMerged, forKey: Self.showRecentlyMergedKey)
        }
    }
    /// Which list the popover should open on. Last selected uses `lastPopoverTab`.
    @Published var popoverTabPreference: PopoverTabPreference {
        didSet {
            guard popoverTabPreference != oldValue else { return }
            UserDefaults.standard.set(popoverTabPreference.rawValue, forKey: Self.popoverTabPreferenceKey)
        }
    }
    /// The tab last chosen in the popover. Used when `popoverTabPreference` is `.lastSelected`.
    @Published var lastPopoverTab: MergeRequestListKind {
        didSet {
            guard lastPopoverTab != oldValue else { return }
            UserDefaults.standard.set(lastPopoverTab.rawValue, forKey: Self.lastPopoverTabKey)
        }
    }
    /// Nil until the user chooses one. Nothing is registered in that case.
    @Published var menuShortcut: MenuShortcut? {
        didSet {
            guard menuShortcut != oldValue else { return }
            if let menuShortcut, let data = try? JSONEncoder().encode(menuShortcut) {
                UserDefaults.standard.set(data, forKey: Self.menuShortcutKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.menuShortcutKey)
            }
        }
    }

    private let defaultsKey = "gitlabMonitor.instances"
    private static let titleParsingKey = "gitlabMonitor.titleParsing"
    private static let sortOrderKey = "gitlabMonitor.sortOrder"
    private static let showThreadBadgesKey = "gitlabMonitor.showThreadBadges"
    private static let showRecentlyMergedKey = "gitlabMonitor.showRecentlyMerged"
    private static let popoverTabPreferenceKey = "gitlabMonitor.popoverTabPreference"
    private static let lastPopoverTabKey = "gitlabMonitor.lastPopoverTab"
    private static let menuShortcutKey = "gitlabMonitor.menuShortcut"
    private var keychain = KeychainStore()

    init() {
        gDebugPrint("AppSettings.init")
        titleParsing = TitleParsing(
            rawValue: UserDefaults.standard.string(forKey: Self.titleParsingKey) ?? ""
        ) ?? .conventionalCommits
        let storedSort = UserDefaults.standard.string(forKey: Self.sortOrderKey) ?? ""
        let resolvedSort = MergeRequestSortOrder.fromStored(storedSort) ?? .createdNewestFirst
        sortOrder = resolvedSort
        if !storedSort.isEmpty, storedSort != resolvedSort.rawValue {
            UserDefaults.standard.set(resolvedSort.rawValue, forKey: Self.sortOrderKey)
        }
        showThreadBadges = UserDefaults.standard.object(forKey: Self.showThreadBadgesKey) as? Bool ?? true
        showRecentlyMerged = UserDefaults.standard.object(forKey: Self.showRecentlyMergedKey) as? Bool ?? true
        popoverTabPreference = PopoverTabPreference(
            rawValue: UserDefaults.standard.string(forKey: Self.popoverTabPreferenceKey) ?? ""
        ) ?? .authored
        lastPopoverTab = MergeRequestListKind(
            rawValue: UserDefaults.standard.string(forKey: Self.lastPopoverTabKey) ?? ""
        ) ?? .authored
        // Drop the old train-animation preference; the merge mark replaced it.
        UserDefaults.standard.removeObject(forKey: "gitlabMonitor.showMergeTrainAnimation")
        if let data = UserDefaults.standard.data(forKey: Self.menuShortcutKey),
           let decoded = try? JSONDecoder().decode(MenuShortcut.self, from: data) {
            menuShortcut = decoded
        } else {
            menuShortcut = nil
            if UserDefaults.standard.object(forKey: Self.menuShortcutKey) != nil {
                UserDefaults.standard.removeObject(forKey: Self.menuShortcutKey)
            }
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([GitLabInstanceConfig].self, from: data) {
            instances = decoded
            gDebugPrint("AppSettings loaded \(instances.count) instance(s) from defaults")
        } else {
            instances = [GitLabInstanceConfig()]
            gDebugPrint("AppSettings using default empty instance")
        }
    }

    func saveInstances(_ updated: [GitLabInstanceConfig]) {
        instances = updated.isEmpty ? [GitLabInstanceConfig()] : updated
        persist()
    }

    func updateInstance(_ instance: GitLabInstanceConfig) {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        instances[index] = instance
        persist()
    }

    func addInstance(_ instance: GitLabInstanceConfig = GitLabInstanceConfig()) {
        instances.append(instance)
        persist()
    }

    func removeInstance(id: UUID) throws {
        try keychain.deleteToken(account: id.uuidString)
        instances.removeAll { $0.id == id }
        if instances.isEmpty {
            instances = [GitLabInstanceConfig()]
        }
        persist()
    }

    /// True when at least one instance has a token. A locked Keychain still counts:
    /// the secret is there, it just cannot be read until this Mac is unlocked.
    var hasConfiguredInstance: Bool {
        instances.contains { lookupToken(for: $0.id) != .missing }
    }

    func lookupToken(for instanceID: UUID) -> TokenLookup {
        keychain.readToken(account: instanceID.uuidString)
    }

    func token(for instanceID: UUID) -> String {
        if case .value(let token) = lookupToken(for: instanceID) {
            return token
        }
        return ""
    }

    func setToken(_ token: String, for instanceID: UUID, notifying: Bool = true) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.deleteToken(account: instanceID.uuidString)
        } else {
            try keychain.saveToken(trimmed, account: instanceID.uuidString)
        }
        if notifying {
            objectWillChange.send()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(instances) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
