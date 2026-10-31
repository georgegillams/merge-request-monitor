//
//  Debug.swift
//  MergeRequestMonitor
//

import Foundation

public func gDebugPrint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    guard isGDebugScheme else { return }
    let message = items.map { "\($0)" }.joined(separator: separator)
    print(message, terminator: terminator)
    fflush(stdout)

    // Also append to a file so logs are visible even when Xcode/console swallow stdout.
    let line = message + (terminator.hasSuffix("\n") ? terminator : terminator + "\n")
    let path = "/tmp/merge-request-monitor-gdebug.log"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
    #endif
}

public var isGDebugScheme: Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains("G_DEBUG")
    #else
    false
    #endif
}

#if DEBUG
/// Sample merge requests for the G_DEBUG scheme.
/// Authored and review lists each exercise pipeline and approval states, across two instances.
enum DebugMergeRequestFixtures {
    private static let gitlabComID = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    private static let acmeID = UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!

    static let mergeRequests: [MergeRequestItem] = [
        item(
            instanceID: acmeID,
            instanceLabel: "Acme GitLab",
            projectID: 860,
            iid: 86,
            title: "Draft: docs(colors): document how status colors map to pipeline stages",
            projectPath: "platform/design-system",
            createdAt: date(daysAgo: 6),
            updatedAt: date(hoursAgo: 1),
            webURL: "https://gitlab.acme.example/platform/design-system/-/merge_requests/86",
            sourceBranch: "docs/status-color-mapping",
            stages: [],
            approvals: ApprovalSummary(
                approvedBy: ["Alex Kim", "Chris Adeyemi", "Noah Berg"],
                approvalsRequired: nil,
                approvalsLeft: nil,
                userHasApproved: false
            ),
            threads: ThreadSummary(resolvable: 2, resolved: 1)
        ),
        item(
            instanceID: acmeID,
            instanceLabel: "Acme GitLab",
            projectID: 1280,
            iid: 128,
            title: "chore(ios): raise the minimum deployment target to iOS 17",
            projectPath: "platform/mobile-ios",
            createdAt: date(daysAgo: 2),
            updatedAt: date(daysAgo: 3),
            webURL: "https://gitlab.acme.example/platform/mobile-ios/-/merge_requests/128",
            sourceBranch: "chore/ios-17-minimum",
            stages: stages([
                ("build", .success),
                ("test", .success),
                ("release", .paused)
            ]),
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: 1,
                approvalsLeft: 1,
                userHasApproved: false
            ),
            threads: .empty
        ),
        // Mixed stack, listed and timestamped out of chain order so grouping
        // cannot be mistaken for "newest child first". Chain is:
        //   1842 (ready, 4d) ← 1837 (ready, 5d) ← 1845 (draft, 1h) ← 1848 (ready, 1d)
        // Ready keeps 1842 / 1837 / 1848. Draft still leads with 1842.
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 1842,
            iid: 1848,
            title: "feat(api): replay failed webhook deliveries from metrics",
            projectPath: "acme/payments-api",
            createdAt: date(daysAgo: 1),
            updatedAt: date(daysAgo: 4),
            webURL: "https://gitlab.com/acme/payments-api/-/merge_requests/1848",
            sourceBranch: "feature/webhook-replay",
            targetBranch: "feature/webhook-metrics",
            defaultBranch: "develop",
            stages: stages([
                ("build", .success),
                ("test", .paused)
            ]),
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: 2,
                approvalsLeft: 2,
                userHasApproved: false
            ),
            threads: .empty
        ),
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 1842,
            iid: 1830,
            title: "feat(api): ship webhook retries for settlement events",
            projectPath: "acme/payments-api",
            createdAt: date(daysAgo: 3),
            updatedAt: date(hoursAgo: 2),
            webURL: "https://gitlab.com/acme/payments-api/-/merge_requests/1830",
            sourceBranch: "feat/webhook-retries",
            targetBranch: "develop",
            defaultBranch: "develop",
            stages: [],
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: nil,
                approvalsLeft: nil,
                userHasApproved: false
            ),
            threads: .empty,
            mergeIndicator: .merged,
            mergedAt: date(hoursAgo: 2)
        ),
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 1842,
            iid: 1845,
            title: "Draft: feat(api): record webhook delivery metrics",
            projectPath: "acme/payments-api",
            createdAt: date(hoursAgo: 1),
            updatedAt: date(hoursAgo: 1),
            webURL: "https://gitlab.com/acme/payments-api/-/merge_requests/1845",
            sourceBranch: "feature/webhook-metrics",
            targetBranch: "feature/webhook-race",
            defaultBranch: "develop",
            stages: stages([
                ("build", .success),
                ("test", .success),
                ("lint", .inProgress)
            ]),
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: 2,
                approvalsLeft: 2,
                userHasApproved: false
            ),
            threads: .empty
        ),
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 1842,
            iid: 1842,
            title: "Add idempotency keys to the refund endpoint",
            projectPath: "acme/payments-api",
            createdAt: date(daysAgo: 4),
            updatedAt: date(hoursAgo: 5),
            webURL: "https://gitlab.com/acme/payments-api/-/merge_requests/1842",
            sourceBranch: "feature/webhooks",
            targetBranch: "develop",
            defaultBranch: "develop",
            stages: stages([
                ("build", .success),
                ("test", .success),
                ("deploy", .success)
            ]),
            approvals: ApprovalSummary(
                approvedBy: ["Maya Patel", "Jordan Lee"],
                approvalsRequired: 2,
                approvalsLeft: 0,
                userHasApproved: false
            ),
            threads: ThreadSummary(resolvable: 3, resolved: 3),
            mergeIndicator: .mergeTrain
        ),
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 1842,
            iid: 1837,
            title: "Fix the race when two settlement webhooks arrive in the same second",
            projectPath: "acme/payments-api",
            createdAt: date(daysAgo: 5),
            updatedAt: date(daysAgo: 2),
            webURL: "https://gitlab.com/acme/payments-api/-/merge_requests/1837",
            sourceBranch: "feature/webhook-race",
            targetBranch: "feature/webhooks",
            defaultBranch: "develop",
            stages: stages([
                ("prepare", .created),
                ("lint", .manual),
                ("test", .failed),
                ("security", .inProgress),
                ("wait", .paused),
                ("publish", .skipped),
                ("notify", .cancelled),
                ("docs", .unknown)
            ]),
            approvals: ApprovalSummary(
                approvedBy: ["Priya Nair"],
                approvalsRequired: 2,
                approvalsLeft: 1,
                userHasApproved: false
            ),
            threads: ThreadSummary(resolvable: 4, resolved: 0)
        ),
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 3100,
            iid: 310,
            title: "Draft: Show a skeleton while the first pipeline is still running",
            projectPath: "acme/web-app",
            createdAt: date(hoursAgo: 5),
            updatedAt: date(daysAgo: 5),
            webURL: "https://gitlab.com/acme/web-app/-/merge_requests/310",
            sourceBranch: "draft/pipeline-skeleton",
            stages: stages([
                ("build", .success),
                ("test", .inProgress)
            ]),
            approvals: ApprovalSummary(
                approvedBy: ["Sam Okonkwo"],
                approvalsRequired: 1,
                approvalsLeft: 0,
                userHasApproved: false
            ),
            threads: ThreadSummary(resolvable: 1, resolved: 0)
        ),
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 440,
            iid: 44,
            title: "Retire the legacy checkout flag once the new storefront experiment has been at 100% for a full week",
            projectPath: "groups/commerce/storefront/checkout-service",
            createdAt: date(hoursAgo: 1),
            updatedAt: date(daysAgo: 4),
            webURL: "https://gitlab.com/groups/commerce/storefront/checkout-service/-/merge_requests/44",
            sourceBranch: "chore/retire-legacy-checkout-flag",
            stages: stages([
                ("build", .cancelled),
                ("notify", .cancelled)
            ]),
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: nil,
                approvalsLeft: nil,
                userHasApproved: false
            ),
            threads: .empty
        )
    ]

    /// MRs assigned to the current user as reviewer. Distinct from `mergeRequests`
    /// so the two popover tabs are visually different in G_DEBUG.
    static let reviewedMergeRequests: [MergeRequestItem] = [
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 2200,
            iid: 91,
            title: "feat(auth): rotate session tokens before they expire",
            projectPath: "acme/identity-service",
            createdAt: date(daysAgo: 2),
            updatedAt: date(hoursAgo: 3),
            webURL: "https://gitlab.com/acme/identity-service/-/merge_requests/91",
            sourceBranch: "feat/session-rotation",
            stages: stages([
                ("build", .success),
                ("test", .success),
                ("security", .paused)
            ]),
            approvals: ApprovalSummary(
                approvedBy: ["Maya Patel"],
                approvalsRequired: 2,
                approvalsLeft: 1,
                userHasApproved: false
            ),
            threads: ThreadSummary(resolvable: 2, resolved: 0)
        ),
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 2200,
            iid: 94,
            title: "Draft: test(auth): cover the session rotation grace period",
            projectPath: "acme/identity-service",
            createdAt: date(hoursAgo: 4),
            updatedAt: date(hoursAgo: 4),
            webURL: "https://gitlab.com/acme/identity-service/-/merge_requests/94",
            sourceBranch: "test/session-rotation-grace",
            targetBranch: "feat/session-rotation",
            stages: stages([
                ("build", .success),
                ("test", .inProgress)
            ]),
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: 2,
                approvalsLeft: 2,
                userHasApproved: false
            ),
            threads: .empty
        ),
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 551,
            iid: 12,
            title: "fix(checkout): stop double-charging when the webhook retries",
            projectPath: "acme/payments-api",
            createdAt: date(daysAgo: 1),
            updatedAt: date(hoursAgo: 6),
            webURL: "https://gitlab.com/acme/payments-api/-/merge_requests/12",
            sourceBranch: "fix/webhook-double-charge",
            stages: stages([
                ("build", .success),
                ("test", .failed),
                ("lint", .success)
            ]),
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: 1,
                approvalsLeft: 1,
                userHasApproved: false
            ),
            threads: ThreadSummary(resolvable: 3, resolved: 1)
        ),
        item(
            instanceID: acmeID,
            instanceLabel: "Acme GitLab",
            projectID: 77,
            iid: 5,
            title: "chore(ci): pin the runner image after the broken 2026.9 tag",
            projectPath: "platform/ci-images",
            createdAt: date(daysAgo: 3),
            updatedAt: date(hoursAgo: 8),
            webURL: "https://gitlab.acme.example/platform/ci-images/-/merge_requests/5",
            sourceBranch: "chore/pin-runner-image",
            stages: stages([
                ("build", .success),
                ("test", .success),
                ("publish", .success)
            ]),
            approvals: ApprovalSummary(
                approvedBy: ["Alex Kim", "Noah Berg"],
                approvalsRequired: 2,
                approvalsLeft: 0,
                userHasApproved: true
            ),
            threads: ThreadSummary(resolvable: 1, resolved: 1),
            mergeIndicator: .mergeTrain
        ),
        item(
            instanceID: gitlabComID,
            instanceLabel: "GitLab.com",
            projectID: 880,
            iid: 33,
            title: "docs(api): document the refund idempotency header",
            projectPath: "acme/developer-docs",
            createdAt: date(daysAgo: 4),
            updatedAt: date(hoursAgo: 3),
            webURL: "https://gitlab.com/acme/developer-docs/-/merge_requests/33",
            sourceBranch: "docs/refund-idempotency",
            stages: [],
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: nil,
                approvalsLeft: nil,
                userHasApproved: false
            ),
            threads: .empty,
            mergeIndicator: .merged,
            mergedAt: date(hoursAgo: 3)
        )
    ]

    static let errors: [InstanceError] = [
        InstanceError(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!,
            instanceLabel: "gitlab.legacy.internal",
            message: "HTTP 401: Unauthorized"
        )
    ]

    private static func stages(_ pairs: [(String, PipelineStageStatus)]) -> [PipelineStage] {
        pairs.enumerated().map { index, pair in
            let (name, status) = pair
            let jobID = 10_000 + index * 10
            return PipelineStage(
                name: name,
                status: status,
                jobs: sampleJobs(for: name, status: status, startingID: jobID)
            )
        }
    }

    /// One or two sample jobs per stage so the stage job list is exercisable in G_DEBUG.
    private static func sampleJobs(
        for stageName: String,
        status: PipelineStageStatus,
        startingID: Int
    ) -> [PipelineJob] {
        let base = "https://gitlab.com/acme/example/-/jobs"
        switch status {
        case .failed:
            return [
                PipelineJob(
                    id: startingID,
                    name: "\(stageName): unit",
                    status: .success,
                    webURL: URL(string: "\(base)/\(startingID)")
                ),
                PipelineJob(
                    id: startingID + 1,
                    name: "\(stageName): integration",
                    status: .failed,
                    webURL: URL(string: "\(base)/\(startingID + 1)")
                )
            ]
        case .inProgress:
            return [
                PipelineJob(
                    id: startingID,
                    name: "\(stageName): unit",
                    status: .success,
                    webURL: URL(string: "\(base)/\(startingID)")
                ),
                PipelineJob(
                    id: startingID + 1,
                    name: "\(stageName): integration",
                    status: .inProgress,
                    webURL: URL(string: "\(base)/\(startingID + 1)")
                )
            ]
        default:
            return [
                PipelineJob(
                    id: startingID,
                    name: stageName,
                    status: status,
                    webURL: URL(string: "\(base)/\(startingID)")
                )
            ]
        }
    }

    /// 2026-10-08 00:00 UTC. Fixture ages are offsets from this so sort order stays stable.
    private static let referenceDate = Date(timeIntervalSince1970: 1_791_417_600)

    private static func date(daysAgo: Int = 0, hoursAgo: Int = 0) -> Date {
        referenceDate.addingTimeInterval(TimeInterval(-(daysAgo * 86_400 + hoursAgo * 3_600)))
    }

    private static func item(
        instanceID: UUID,
        instanceLabel: String,
        projectID: Int,
        iid: Int,
        title: String,
        projectPath: String,
        createdAt: Date,
        updatedAt: Date,
        webURL: String,
        sourceBranch: String = "",
        targetBranch: String = "main",
        defaultBranch: String = "main",
        stages: [PipelineStage],
        approvals: ApprovalSummary,
        threads: ThreadSummary,
        mergeIndicator: MergeIndicator = .none,
        mergedAt: Date? = nil
    ) -> MergeRequestItem {
        MergeRequestItem(
            id: "\(instanceID.uuidString)-\(projectID)-\(iid)",
            instanceID: instanceID,
            instanceLabel: instanceLabel,
            projectID: projectID,
            iid: iid,
            title: title,
            projectPath: projectPath,
            webURL: URL(string: webURL),
            sourceBranch: sourceBranch,
            targetBranch: targetBranch,
            defaultBranch: defaultBranch,
            stages: stages,
            approvals: approvals,
            threads: threads,
            mergeIndicator: mergeIndicator,
            mergedAt: mergedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
#endif
