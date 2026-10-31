//
//  SettingsView.swift
//  MergeRequestMonitor
//

import AppKit
import SwiftUI
import LaunchAtLogin
import components_swiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: RefreshCoordinator
    @ObservedObject var menuShortcutMonitor: MenuShortcutMonitor
    var onInstancesChanged: () -> Void = {}

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var tokenDrafts: [UUID: String] = [:]
    @State private var tokenStoreError: String?

    var body: some View {
        VStack(spacing: 0) {
            form
            creditFooter
        }
        .frame(minWidth: 560, minHeight: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Grouped forms paint the system window grey. The previous pure-black
            // backdrop showed as a dark frame around that grey.
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            for instance in settings.instances where tokenDrafts[instance.id] == nil {
                // A locked Keychain cannot yield the token. Leave the field unset so a
                // blank value is not written back over the stored secret.
                switch settings.lookupToken(for: instance.id) {
                case .value(let token):
                    tokenDrafts[instance.id] = token
                case .missing:
                    tokenDrafts[instance.id] = ""
                case .locked:
                    break
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                if settings.instances.isEmpty {
                    Text("No GitLab instances yet. Add one to start monitoring your merge requests.")
                        .foregroundStyle(Semantic.Colors.textDisabled)
                }

                ForEach(settings.instances) { instance in
                    InstanceEditor(
                        instance: instance,
                        token: binding(for: instance.id),
                        coordinator: coordinator,
                        onChange: { updated in
                            settings.updateInstance(updated)
                            onInstancesChanged()
                        },
                        onTokenEdit: { token in
                            storeToken(token, for: instance.id, notifying: false)
                        },
                        onTokenCommit: { token in
                            guard storeToken(token, for: instance.id, notifying: true) else { return }
                            onInstancesChanged()
                        },
                        onRemove: {
                            do {
                                try settings.removeInstance(id: instance.id)
                                tokenDrafts[instance.id] = nil
                                tokenStoreError = nil
                                onInstancesChanged()
                            } catch {
                                tokenStoreError = error.localizedDescription
                            }
                        },
                        canRemove: settings.instances.count > 1
                    )
                }

                Button {
                    let instance = GitLabInstanceConfig()
                    settings.addInstance(instance)
                    tokenDrafts[instance.id] = ""
                    onInstancesChanged()
                } label: {
                    Label("Add GitLab instance", systemImage: "plus.circle")
                }
            } header: {
                Text("GitLab instances")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let tokenStoreError {
                        Text(tokenStoreError)
                            .foregroundStyle(Semantic.Colors.statusDestructive)
                    }
                    Text("Tokens stay in the Keychain on this Mac. They are unreadable while it is locked, and they are not synced or backed up. Use a personal access token with `read_api` scope.")
                        .foregroundStyle(Semantic.Colors.textDisabled)
                }
            }

            Section("General") {
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                        Text("Start Merge Request Monitor automatically when you log in.")
                            .font(.caption)
                            .foregroundStyle(Semantic.Colors.textDisabled)
                    }
                }
                .onChange(of: launchAtLogin) { value in
                    LaunchAtLogin.isEnabled = value
                }

                LabeledContent {
                    ShortcutRecorder(
                        shortcut: $settings.menuShortcut,
                        monitor: menuShortcutMonitor
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Popover shortcut")
                        Text("Show or hide the popover from any app. Unset until you choose one.")
                            .font(.caption)
                            .foregroundStyle(Semantic.Colors.textDisabled)
                    }
                }

                if let registrationError = menuShortcutMonitor.registrationError {
                    Text(registrationError)
                        .font(.caption)
                        .foregroundStyle(Semantic.Colors.statusDestructive)
                }

                Picker(selection: $settings.popoverTabPreference) {
                    ForEach(PopoverTabPreference.allCases, id: \.self) { preference in
                        Text(preference.label).tag(preference)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default popover tab")
                        Text("Open on your merge requests, requested reviews, or whichever you last viewed.")
                            .font(.caption)
                            .foregroundStyle(Semantic.Colors.textDisabled)
                    }
                }
                .pickerStyle(.menu)

                Picker(selection: $settings.sortOrder) {
                    ForEach(MergeRequestSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sort order")
                        Text("Order by when a merge request was opened or last edited.")
                            .font(.caption)
                            .foregroundStyle(Semantic.Colors.textDisabled)
                    }
                }
                .pickerStyle(.menu)

                Toggle(isOn: conventionalCommitTitles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Conventional commit titles")
                        Text("Show only the description from titles like feat(api): add refunds.")
                            .font(.caption)
                            .foregroundStyle(Semantic.Colors.textDisabled)
                    }
                }

                Toggle(isOn: $settings.showThreadBadges) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show discussion threads")
                        Text("Show how many review threads are resolved on each merge request.")
                            .font(.caption)
                            .foregroundStyle(Semantic.Colors.textDisabled)
                    }
                }
            }

            listFiltersSection(
                kind: .authored,
                filters: $settings.authoredFilters
            )
            listFiltersSection(
                kind: .requestedReviews,
                filters: $settings.requestedReviewFilters
            )

            Section("About") {
                LabeledContent("Version", value: Bundle.main.menuBuildLabel)
                Link("Provide feedback", destination: Bundle.main.feedbackURL).foregroundStyle(Semantic.Colors.textLink)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, Primitive.Layout.spacingBase)
        .padding(.bottom, Primitive.Layout.spacingBase)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var creditFooter: some View {
        Text(creditText)
            .font(.callout)
            .foregroundStyle(Semantic.Colors.textDisabled)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Primitive.Layout.spacingBase)
            .padding(.bottom, Primitive.Layout.spacingBase)
    }

    private var creditText: AttributedString {
        let markdown = "Made with ❤️ by [George Gillams](\(Bundle.main.authorURL.absoluteString))"
        var attributed = (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString("Made with ❤️ by George Gillams")
        let ranges = attributed.runs.compactMap { run in
            run.link != nil ? run.range : nil
        }
        for range in ranges {
            attributed[range].foregroundColor = Semantic.Colors.textLink
            attributed[range].underlineStyle = Text.LineStyle(pattern: .solid, color: .clear)
        }
        return attributed
    }

    @ViewBuilder
    private func listFiltersSection(
        kind: MergeRequestListKind,
        filters: Binding<MergeRequestListFilters>
    ) -> some View {
        Section(kind.tabTitle) {
            Toggle(isOn: filters.showRecentlyMerged) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show recently merged")
                    Text("Include merge requests merged in the last \(kind.recentlyMergedWindowHours) hours.")
                        .font(.caption)
                        .foregroundStyle(Semantic.Colors.textDisabled)
                }
            }

            Toggle(isOn: filters.showDrafts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show drafts")
                    Text("Include merge requests marked as drafts.")
                        .font(.caption)
                        .foregroundStyle(Semantic.Colors.textDisabled)
                }
            }
        }
    }

    @discardableResult
    private func storeToken(_ token: String, for id: UUID, notifying: Bool) -> Bool {
        do {
            try settings.setToken(token, for: id, notifying: notifying)
            tokenStoreError = nil
            return true
        } catch {
            tokenStoreError = error.localizedDescription
            return false
        }
    }

    /// The switch writes the title-parsing enum. Off clears it back to `.none`.
    private var conventionalCommitTitles: Binding<Bool> {
        Binding(
            get: { settings.titleParsing == .conventionalCommits },
            set: { enabled in
                settings.titleParsing = enabled ? .conventionalCommits : .none
            }
        )
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { tokenDrafts[id] ?? settings.token(for: id) },
            set: { tokenDrafts[id] = $0 }
        )
    }
}

private struct InstanceEditor: View {
    let instance: GitLabInstanceConfig
    @Binding var token: String
    @ObservedObject var coordinator: RefreshCoordinator
    var onChange: (GitLabInstanceConfig) -> Void
    var onTokenEdit: (String) -> Void
    var onTokenCommit: (String) -> Void
    var onRemove: () -> Void
    var canRemove: Bool

    @State private var label: String
    @State private var baseURL: String
    @State private var confirmingRemoval = false
    /// Token text while the secure field is focused. The binding updates only on commit.
    @State private var liveToken: String? = nil

    init(
        instance: GitLabInstanceConfig,
        token: Binding<String>,
        coordinator: RefreshCoordinator,
        onChange: @escaping (GitLabInstanceConfig) -> Void,
        onTokenEdit: @escaping (String) -> Void,
        onTokenCommit: @escaping (String) -> Void,
        onRemove: @escaping () -> Void,
        canRemove: Bool
    ) {
        self.instance = instance
        self._token = token
        self._coordinator = ObservedObject(wrappedValue: coordinator)
        self.onChange = onChange
        self.onTokenEdit = onTokenEdit
        self.onTokenCommit = onTokenCommit
        self.onRemove = onRemove
        self.canRemove = canRemove
        _label = State(initialValue: instance.label)
        _baseURL = State(initialValue: instance.baseURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Primitive.Layout.spacingBase) {
            TextField("Label (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitMetadata)
                .onChange(of: label) { _ in commitMetadata() }

            TextField("GitLab URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitMetadata)
                .onChange(of: baseURL) { _ in
                    normalizeBaseURLScheme()
                    commitMetadata()
                }

            LabeledContent("Bearer token") {
                SecureTokenField(
                    text: $token,
                    onEdit: { value in
                        liveToken = value
                        onTokenEdit(value)
                    },
                    onCommit: { value in
                        liveToken = value
                        onTokenCommit(value)
                    }
                )
            }

            HStack(alignment: .center, spacing: Primitive.Layout.spacingSm) {
                Button {
                    guard let url = personalAccessTokensURL else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Manage tokens", systemImage: "key")
                }
                .disabled(personalAccessTokensURL == nil)
                .help(personalAccessTokensURL == nil
                    ? "Enter a GitLab URL to open its token page"
                    : "Open personal access tokens in your browser")

                InstanceStatusBadge(status: connectionStatus)
                Spacer(minLength: Primitive.Layout.spacingSm)
                if canRemove {
                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Remove instance")
                    .confirmationDialog(
                        "Remove this GitLab instance?",
                        isPresented: $confirmingRemoval,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive, action: onRemove)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The instance configuration and stored token will be deleted.")
                    }
                }
            }
            .padding(.top, Primitive.Layout.spacingSm)
        }
        .padding(.vertical, Primitive.Layout.spacingBase)
        .onAppear {
            label = instance.label
            baseURL = instance.baseURL
            normalizeBaseURLScheme()
            if baseURL != instance.baseURL {
                commitMetadata()
            }
        }
    }

    /// Personal access tokens page for the URL currently in the field.
    /// Requires https. Nil when the field is empty, still on http, or not a usable GitLab URL.
    private var personalAccessTokensURL: URL? {
        Self.personalAccessTokensURL(from: baseURL)
    }

    static func personalAccessTokensURL(from rawBaseURL: String) -> URL? {
        var value = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let lowercased = value.lowercased()
        if lowercased.hasPrefix("http://") {
            return nil
        }
        if !lowercased.hasPrefix("https://") {
            value = "https://\(value)"
        }

        guard var components = URLComponents(string: value),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        components.scheme = "https"
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        if path == "/" {
            path = ""
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path + "/-/user_settings/personal_access_tokens"
        return components.url
    }

    /// Rewrites `http://` to `https://` in the URL field as the value is edited.
    private func normalizeBaseURLScheme() {
        let secured = Self.replacingHTTPSchemeWithHTTPS(baseURL)
        if secured != baseURL {
            baseURL = secured
        }
    }

    static func replacingHTTPSchemeWithHTTPS(_ rawBaseURL: String) -> String {
        let lowercased = rawBaseURL.lowercased()
        guard lowercased.hasPrefix("http://") else { return rawBaseURL }
        var value = rawBaseURL
        value.replaceSubrange(
            value.startIndex..<value.index(value.startIndex, offsetBy: "http://".count),
            with: "https://"
        )
        return value
    }

    /// Empty URL or token is not configured.
    /// Connected only after a fetch for this instance has succeeded.
    /// A failed fetch is inactive. The first attempt stays not configured until that result arrives.
    private var connectionStatus: InstanceConnectionStatus {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentToken = (liveToken ?? token).trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty || currentToken.isEmpty {
            return .notConfigured
        }
        if coordinator.connectedInstanceIDs.contains(instance.id) {
            return .connected
        }
        let fetchFailed = coordinator.errors.contains {
            $0.id == instance.id && $0.kind == .fetchFailed
        }
        return fetchFailed ? .inactive : .notConfigured
    }

    private func commitMetadata() {
        normalizeBaseURLScheme()
        var updated = instance
        updated.label = label
        updated.baseURL = baseURL
        onChange(updated)
    }
}

private enum InstanceConnectionStatus {
    case notConfigured
    case inactive
    case connected

    var title: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .inactive: return "Inactive"
        case .connected: return "Connected"
        }
    }

    var color: Color {
        switch self {
        case .notConfigured, .inactive:
            return Semantic.Colors.statusDestructive
        case .connected:
            return Semantic.Colors.statusSuccess
        }
    }
}

private struct InstanceStatusBadge: View {
    let status: InstanceConnectionStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(status.title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.title)")
    }
}

/// NSSecureTextField accepts paste. SwiftUI `SecureField` on macOS does not,
/// and this app previously had no Edit menu so Cmd+V never reached the field.
private struct SecureTokenField: NSViewRepresentable {
    @Binding var text: String
    var onEdit: (String) -> Void
    var onCommit: (String) -> Void

    func makeNSView(context: Context) -> PasteableSecureTextField {
        let field = PasteableSecureTextField()
        field.stringValue = text
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return field
    }

    func updateNSView(_ nsView: PasteableSecureTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEdit = onEdit
        context.coordinator.onCommit = onCommit
        // Don't push SwiftUI state back into the field editor mid-edit, or a paste is wiped.
        guard nsView.currentEditor() == nil else { return }
        guard nsView.stringValue != text else { return }
        nsView.stringValue = text
        context.coordinator.lastCommitted = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PasteableSecureTextField, context: Context) -> CGSize? {
        let height = max(nsView.intrinsicContentSize.height, 22)
        // Prefer the parent proposal so a long token can't force the field wider than siblings.
        if let width = proposal.width, width.isFinite, width > 0 {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: 120, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEdit: onEdit, onCommit: onCommit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onEdit: (String) -> Void
        var onCommit: (String) -> Void
        var lastCommitted: String

        init(text: Binding<String>, onEdit: @escaping (String) -> Void, onCommit: @escaping (String) -> Void) {
            self.text = text
            self.onEdit = onEdit
            self.onCommit = onCommit
            self.lastCommitted = text.wrappedValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Keep this out of SwiftUI state. Republishing mid-paste recreates the field and drops the paste.
            onEdit(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            commit(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let field = control as? NSTextField else {
                return false
            }
            commit(field.stringValue)
            return true
        }

        private func commit(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != lastCommitted else { return }
            lastCommitted = value
            text.wrappedValue = value
            onCommit(value)
        }
    }
}

/// Secure field that handles Cmd+V itself. Menu-item validation on the secure field editor
/// often leaves Paste disabled, so the Edit menu alone is not enough.
private final class PasteableSecureTextField: NSSecureTextField {
    private var pasteMonitor: Any?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        guard accepted else { return false }
        if let editor = currentEditor() as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
        }
        installPasteMonitor()
        return true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            removePasteMonitor()
        }
        return resigned
    }

    deinit {
        removePasteMonitor()
    }

    private func installPasteMonitor() {
        removePasteMonitor()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.currentEditor() != nil else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command),
                  !flags.contains(.control),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }
            self.currentEditor()?.paste(nil)
            return nil
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
            self.pasteMonitor = nil
        }
    }
}
