//
//  MergeRequestStackTests.swift
//  MergeRequestMonitorTests
//

import XCTest
@testable import MergeRequestMonitor

final class MergeRequestStackTests: XCTestCase {
    func testIndependentRootsKeepSortOrderAndPullStackedChildUnderParent() {
        // Sorted oldest → newest: MR1, MR2, MR3. MR3 is stacked on MR1, not MR2.
        let items = [
            item(id: "mr1", iid: 1, title: "MR1", source: "branch-1", target: "develop", created: 1),
            item(id: "mr2", iid: 2, title: "MR2", source: "branch-2", target: "develop", created: 2),
            item(id: "mr3", iid: 3, title: "MR3", source: "branch-3", target: "branch-1", created: 3)
        ]

        XCTAssertEqual(
            titles(MergeRequestSortOrder.createdOldestFirst.grouped(items)),
            [["MR1", "MR3"], ["MR2"]]
        )
    }

    func testStackedChildDoesNotTakeATopLevelSlotWhenItSortsFirst() {
        let items = [
            item(id: "mr1", iid: 1, title: "MR1", source: "branch-1", target: "develop", created: 1),
            item(id: "mr2", iid: 2, title: "MR2", source: "branch-2", target: "develop", created: 2),
            item(id: "mr3", iid: 3, title: "MR3", source: "branch-3", target: "branch-1", created: 3)
        ]

        // Newest first would list MR3, MR2, MR1. MR3 still sits under MR1;
        // MR2 stays a top-level sibling of MR1, in MR2's own sort position.
        XCTAssertEqual(
            titles(MergeRequestSortOrder.createdNewestFirst.grouped(items)),
            [["MR2"], ["MR1", "MR3"]]
        )
    }

    func testInputOrderDoesNotChangeStackGrouping() {
        let items = [
            item(id: "mr3", iid: 3, title: "MR3", source: "branch-3", target: "branch-1", created: 3),
            item(id: "mr2", iid: 2, title: "MR2", source: "branch-2", target: "develop", created: 2),
            item(id: "mr1", iid: 1, title: "MR1", source: "branch-1", target: "develop", created: 1)
        ]

        XCTAssertEqual(
            titles(MergeRequestSortOrder.createdOldestFirst.grouped(items)),
            [["MR1", "MR3"], ["MR2"]]
        )
    }

    func testThreeDeepStackFlattensUnderTheBaseEvenWhenDatesAreOutOfChainOrder() {
        // Chain is MR1 ← MR2 ← MR3, but MR3 is oldest and MR2 is newest.
        let items = [
            item(id: "mr3", iid: 3, title: "MR3", source: "feature-3", target: "feature-2", created: 1),
            item(id: "mr1", iid: 1, title: "MR1", source: "feature-1", target: "develop", created: 5),
            item(id: "mr2", iid: 2, title: "MR2", source: "feature-2", target: "feature-1", created: 9)
        ]

        let groups = MergeRequestSortOrder.createdOldestFirst.grouped(items)
        XCTAssertEqual(titles(groups), [["MR1", "MR2", "MR3"]])
        XCTAssertEqual(groups.first?.stacked.count, 2)
    }

    func testMRIntoDefaultBranchIsNotStackedOnAnMRThatUsesThatBranchAsSource() {
        let items = [
            item(id: "promote", iid: 1, title: "Promote develop", source: "develop", target: "staging", created: 2),
            item(id: "feature", iid: 2, title: "Feature into develop", source: "feature-1", target: "develop", created: 1)
        ]

        XCTAssertEqual(
            titles(MergeRequestSortOrder.createdNewestFirst.grouped(items)),
            [["Promote develop"], ["Feature into develop"]]
        )
    }

    func testReadySectionKeepsOnlyNonDraftsFromAMixedStack() {
        // Draft leaf is oldest; ready middle is newest. Stack order is still chain order.
        let items = [
            item(id: "mr3", iid: 3, title: "Draft: Draft top", source: "feature-3", target: "feature-2", created: 1),
            item(id: "mr1", iid: 1, title: "Ready base", source: "feature-1", target: "develop", created: 4),
            item(id: "mr2", iid: 2, title: "Ready middle", source: "feature-2", target: "feature-1", created: 9)
        ]

        let sections = MergeRequestSortOrder.createdOldestFirst.sectioned(items)
        XCTAssertEqual(titles(sections.merged), [])
        XCTAssertEqual(titles(sections.mergeQueue), [])
        XCTAssertEqual(titles(sections.ready), [["Ready base", "Ready middle"]])
        XCTAssertEqual(titles(sections.draft), [["Ready base", "Draft: Draft top"]])
    }

    func testDraftSectionShowsReadyRootEvenWhenOnlyDescendantsAreDraft() {
        let items = [
            item(id: "mr2", iid: 2, title: "Draft: Draft child", source: "feature-2", target: "feature-1", created: 8),
            item(id: "mr1", iid: 1, title: "Ready base", source: "feature-1", target: "develop", created: 2)
        ]

        let sections = MergeRequestSortOrder.createdOldestFirst.sectioned(items)
        XCTAssertEqual(titles(sections.merged), [])
        XCTAssertEqual(titles(sections.mergeQueue), [])
        XCTAssertEqual(titles(sections.ready), [["Ready base"]])
        XCTAssertEqual(titles(sections.draft), [["Ready base", "Draft: Draft child"]])
    }

    func testReadySectionPromotesReadyChildrenWhenTheStackRootIsDraft() {
        let items = [
            item(id: "mr2", iid: 2, title: "Ready child", source: "feature-2", target: "feature-1", created: 9),
            item(id: "mr3", iid: 3, title: "Draft: Draft grandchild", source: "feature-3", target: "feature-2", created: 1),
            item(id: "mr1", iid: 1, title: "Draft: Draft base", source: "feature-1", target: "develop", created: 4)
        ]

        let sections = MergeRequestSortOrder.createdOldestFirst.sectioned(items)
        XCTAssertEqual(titles(sections.merged), [])
        XCTAssertEqual(titles(sections.mergeQueue), [])
        XCTAssertEqual(titles(sections.ready), [["Ready child"]])
        XCTAssertEqual(titles(sections.draft), [["Draft: Draft base", "Draft: Draft grandchild"]])
    }

    func testReadyDescendantsStayStackedThroughADraftIntermediate() {
        // Newest MR is the draft in the middle; ready leaf is older than the base.
        let items = [
            item(id: "mr3", iid: 3, title: "Ready leaf", source: "feature-3", target: "feature-2", created: 2),
            item(id: "mr2", iid: 2, title: "Draft: Draft middle", source: "feature-2", target: "feature-1", created: 9),
            item(id: "mr1", iid: 1, title: "Ready base", source: "feature-1", target: "develop", created: 4)
        ]

        let sections = MergeRequestSortOrder.createdOldestFirst.sectioned(items)
        XCTAssertEqual(titles(sections.merged), [])
        XCTAssertEqual(titles(sections.mergeQueue), [])
        XCTAssertEqual(titles(sections.ready), [["Ready base", "Ready leaf"]])
        XCTAssertEqual(titles(sections.draft), [["Ready base", "Draft: Draft middle"]])
    }

    func testIndependentDraftsFollowReadyGroupsAndKeepSortOrder() {
        let items = [
            item(id: "ready-old", iid: 1, title: "Ready old", source: "ready-old", target: "develop", created: 1),
            item(id: "draft", iid: 2, title: "Draft: Standalone", source: "draft-1", target: "develop", created: 2),
            item(id: "ready-new", iid: 3, title: "Ready new", source: "ready-new", target: "develop", created: 3)
        ]

        let sections = MergeRequestSortOrder.createdNewestFirst.sectioned(items)
        XCTAssertEqual(titles(sections.merged), [])
        XCTAssertEqual(titles(sections.mergeQueue), [])
        XCTAssertEqual(titles(sections.ready), [["Ready new"], ["Ready old"]])
        XCTAssertEqual(titles(sections.draft), [["Draft: Standalone"]])
    }

    func testMergedSectionLeadsAndIsOmittedWhenEmpty() {
        let items = [
            item(id: "ready", iid: 1, title: "Ready", source: "ready", target: "develop", created: 1),
            item(
                id: "merged",
                iid: 2,
                title: "Merged",
                source: "merged",
                target: "develop",
                created: 3,
                mergeIndicator: .merged,
                mergedAt: Date(timeIntervalSince1970: 4)
            ),
            item(id: "draft", iid: 3, title: "Draft: Draft", source: "draft", target: "develop", created: 2)
        ]

        let sections = MergeRequestSortOrder.createdNewestFirst.sectioned(items)
        XCTAssertEqual(titles(sections.merged), [["Merged"]])
        XCTAssertEqual(titles(sections.mergeQueue), [])
        XCTAssertEqual(titles(sections.ready), [["Ready"]])
        XCTAssertEqual(titles(sections.draft), [["Draft: Draft"]])
    }

    func testMergeQueueSitsAfterMergedAndLeavesTheReadyStack() {
        let items = [
            item(id: "ready", iid: 1, title: "Ready base", source: "feature-1", target: "develop", created: 4),
            item(
                id: "queued",
                iid: 2,
                title: "Queued",
                source: "feature-2",
                target: "feature-1",
                created: 2,
                mergeIndicator: .mergeTrain
            ),
            item(
                id: "merged",
                iid: 3,
                title: "Merged",
                source: "merged",
                target: "develop",
                created: 1,
                mergeIndicator: .merged,
                mergedAt: Date(timeIntervalSince1970: 5)
            )
        ]

        let sections = MergeRequestSortOrder.createdOldestFirst.sectioned(items)
        XCTAssertEqual(titles(sections.merged), [["Merged"]])
        XCTAssertEqual(titles(sections.mergeQueue), [["Queued"]])
        XCTAssertEqual(titles(sections.ready), [["Ready base"]])
        XCTAssertEqual(titles(sections.draft), [])
    }

    func testMergedMembersLeaveTheReadyStack() {
        let items = [
            item(id: "mr1", iid: 1, title: "Ready base", source: "feature-1", target: "develop", created: 4),
            item(
                id: "mr2",
                iid: 2,
                title: "Merged middle",
                source: "feature-2",
                target: "feature-1",
                created: 2,
                mergeIndicator: .merged,
                mergedAt: Date(timeIntervalSince1970: 3)
            ),
            item(id: "mr3", iid: 3, title: "Ready leaf", source: "feature-3", target: "feature-2", created: 1)
        ]

        let sections = MergeRequestSortOrder.createdOldestFirst.sectioned(items)
        XCTAssertEqual(titles(sections.merged), [["Merged middle"]])
        XCTAssertEqual(titles(sections.mergeQueue), [])
        XCTAssertEqual(titles(sections.ready), [["Ready base", "Ready leaf"]])
        XCTAssertEqual(titles(sections.draft), [])
    }

    private func titles(_ groups: [MergeRequestGroup]) -> [[String]] {
        groups.map { [$0.root.title] + $0.stacked.map(\.title) }
    }

    private func item(
        id: String,
        iid: Int,
        title: String,
        source: String,
        target: String,
        created: Int,
        mergeIndicator: MergeIndicator = .none,
        mergedAt: Date? = nil
    ) -> MergeRequestItem {
        MergeRequestItem(
            id: id,
            instanceID: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!,
            instanceLabel: "GitLab",
            projectID: 1,
            iid: iid,
            title: title,
            projectPath: "acme/app",
            webURL: nil,
            sourceBranch: source,
            targetBranch: target,
            defaultBranch: "develop",
            stages: [],
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: nil,
                approvalsLeft: nil,
                userHasApproved: false
            ),
            threads: .empty,
            mergeIndicator: mergeIndicator,
            mergedAt: mergedAt,
            createdAt: Date(timeIntervalSince1970: TimeInterval(created)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(created))
        )
    }
}

final class PopoverTabPreferenceTests: XCTestCase {
    func testAuthoredPreferenceOpensOnAuthoredRegardlessOfLastTab() {
        XCTAssertEqual(
            PopoverTabPreference.authored.initialTab(lastSelected: .requestedReviews),
            .authored
        )
    }

    func testRequestedPreferenceOpensOnReviewsRegardlessOfLastTab() {
        XCTAssertEqual(
            PopoverTabPreference.requestedReviews.initialTab(lastSelected: .authored),
            .requestedReviews
        )
    }

    func testLastSelectedPreferenceUsesStoredTab() {
        XCTAssertEqual(
            PopoverTabPreference.lastSelected.initialTab(lastSelected: .requestedReviews),
            .requestedReviews
        )
        XCTAssertEqual(
            PopoverTabPreference.lastSelected.initialTab(lastSelected: .authored),
            .authored
        )
    }

    func testListKindUsesGitLabReviewerScope() {
        XCTAssertEqual(MergeRequestListKind.authored.gitLabScope, "created_by_me")
        XCTAssertEqual(MergeRequestListKind.requestedReviews.gitLabScope, "reviews_for_me")
    }

    func testOtherTabTitleAndLabels() {
        XCTAssertEqual(MergeRequestListKind.requestedReviews.tabTitle, "Other merge requests")
        XCTAssertEqual(PopoverTabPreference.requestedReviews.label, "Other merge requests")
        XCTAssertEqual(
            MergeRequestListKind.requestedReviews.tabLabel(count: 3),
            "Other merge requests (3)"
        )
        XCTAssertEqual(
            MergeRequestListKind.authored.tabLabel(count: 0),
            "My merge requests (0)"
        )
    }

    func testRequestedReviewsUseAShorterRecentlyMergedWindow() {
        XCTAssertEqual(MergeRequestListKind.authored.recentlyMergedWindowHours, 12)
        XCTAssertEqual(MergeRequestListKind.requestedReviews.recentlyMergedWindowHours, 4)
        XCTAssertEqual(MergeRequestListKind.authored.recentlyMergedWindow, 12 * 60 * 60)
        XCTAssertEqual(MergeRequestListKind.requestedReviews.recentlyMergedWindow, 4 * 60 * 60)
    }

    func testRequestedEmptyMessageFollowsRecentlyMergedSetting() {
        XCTAssertTrue(
            MergeRequestListKind.requestedReviews.emptyMessage(showRecentlyMerged: true)
                .contains("recently merged")
        )
        XCTAssertFalse(
            MergeRequestListKind.requestedReviews.emptyMessage(showRecentlyMerged: false)
                .contains("recently merged")
        )
    }
}

final class OtherMergeRequestSourcesTests: XCTestCase {
    func testDefaultIncludesAllSources() {
        XCTAssertEqual(
            OtherMergeRequestSources.default,
            [.reviewRequests, .watchedRepos, .subscribed]
        )
    }
}

final class TabCountStatusesTests: XCTestCase {
    func testDefaultCountsReadyAndMergeTrainOnly() {
        XCTAssertEqual(TabCountStatuses.default, [.ready, .mergeTrain])
        let ready = item(id: "ready", title: "Ready", mergeIndicator: .none)
        let train = item(id: "train", title: "Train", mergeIndicator: .mergeTrain)
        let draft = item(id: "draft", title: "Draft: WIP", mergeIndicator: .none)
        let merged = item(id: "merged", title: "Merged", mergeIndicator: .merged)
        XCTAssertEqual(
            TabCountStatuses.default.count(in: [ready, train, draft, merged]),
            2
        )
    }

    func testCustomStatusesCanIncludeDraftAndMerged() {
        let statuses: TabCountStatuses = [.draft, .merged]
        let ready = item(id: "ready", title: "Ready", mergeIndicator: .none)
        let draft = item(id: "draft", title: "Draft: WIP", mergeIndicator: .none)
        let merged = item(id: "merged", title: "Merged", mergeIndicator: .merged)
        XCTAssertEqual(statuses.count(in: [ready, draft, merged]), 2)
    }

    private func item(
        id: String,
        title: String,
        mergeIndicator: MergeIndicator
    ) -> MergeRequestItem {
        MergeRequestItem(
            id: id,
            instanceID: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!,
            instanceLabel: "GitLab",
            projectID: 1,
            iid: 1,
            title: title,
            projectPath: "acme/app",
            webURL: nil,
            sourceBranch: "feature",
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
            mergeIndicator: mergeIndicator,
            mergedAt: mergeIndicator == .merged ? Date(timeIntervalSince1970: 1) : nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

final class MergeRequestListFiltersTests: XCTestCase {
    func testAuthoredDefaultsIncludeMergedAndDrafts() {
        XCTAssertEqual(
            MergeRequestListFilters.authoredDefault,
            MergeRequestListFilters(showRecentlyMerged: true, showDrafts: true)
        )
    }

    func testRequestedReviewDefaultsHideMergedAndDrafts() {
        XCTAssertEqual(
            MergeRequestListFilters.requestedReviewsDefault,
            MergeRequestListFilters(showRecentlyMerged: false, showDrafts: false)
        )
    }

    func testApplyingHidesMergedAndDraftsIndependently() {
        let ready = item(id: "ready", title: "Ready", mergeIndicator: .none)
        let draft = item(id: "draft", title: "Draft: Hidden", mergeIndicator: .none)
        let merged = item(id: "merged", title: "Merged", mergeIndicator: .merged)
        let items = [ready, draft, merged]

        XCTAssertEqual(
            MergeRequestListFilters(showRecentlyMerged: true, showDrafts: true)
                .applying(to: items).map(\.id),
            ["ready", "draft", "merged"]
        )
        XCTAssertEqual(
            MergeRequestListFilters(showRecentlyMerged: false, showDrafts: true)
                .applying(to: items).map(\.id),
            ["ready", "draft"]
        )
        XCTAssertEqual(
            MergeRequestListFilters(showRecentlyMerged: true, showDrafts: false)
                .applying(to: items).map(\.id),
            ["ready", "merged"]
        )
        XCTAssertEqual(
            MergeRequestListFilters(showRecentlyMerged: false, showDrafts: false)
                .applying(to: items).map(\.id),
            ["ready"]
        )
    }

    private func item(
        id: String,
        title: String,
        mergeIndicator: MergeIndicator
    ) -> MergeRequestItem {
        MergeRequestItem(
            id: id,
            instanceID: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!,
            instanceLabel: "GitLab",
            projectID: 1,
            iid: 1,
            title: title,
            projectPath: "acme/app",
            webURL: nil,
            sourceBranch: "feature",
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
            mergeIndicator: mergeIndicator,
            mergedAt: mergeIndicator == .merged ? Date(timeIntervalSince1970: 1) : nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

final class GitLabTokenExpiryTests: XCTestCase {
    func testParsesExpiryAsMidnightUTC() throws {
        let date = try XCTUnwrap(GitLabTokenExpiry.expiresAt(fromAPIDate: "2026-11-12"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 11)
        XCTAssertEqual(parts.day, 12)
        XCTAssertEqual(parts.hour, 0)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertEqual(parts.second, 0)
    }

    func testMissingExpiryDate() {
        XCTAssertNil(GitLabTokenExpiry.expiresAt(fromAPIDate: nil))
        XCTAssertNil(GitLabTokenExpiry.expiresAt(fromAPIDate: ""))
        XCTAssertNil(GitLabTokenExpiry.expiresAt(fromAPIDate: "   "))
        XCTAssertNil(GitLabTokenExpiry.expiresAt(fromAPIDate: "2026-11-12T00:00:00Z"))
    }

    func testWarningWindowIncludesTheSeventhDayAndExpiredTokens() {
        let expires = Date(timeIntervalSince1970: 1_700_000_000)
        let week: TimeInterval = 7 * 24 * 60 * 60
        XCTAssertTrue(GitLabTokenExpiry.isWithinWarningWindow(expiresAt: expires, now: expires.addingTimeInterval(-week)))
        XCTAssertFalse(GitLabTokenExpiry.isWithinWarningWindow(expiresAt: expires, now: expires.addingTimeInterval(-week - 1)))
        XCTAssertTrue(GitLabTokenExpiry.isWithinWarningWindow(expiresAt: expires, now: expires.addingTimeInterval(3600)))
    }

    func testTimeLeftLabel() {
        let expires = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            GitLabTokenExpiry.timeLeftLabel(expiresAt: expires, now: expires.addingTimeInterval(-(3 * day + 4 * hour))),
            "Expires in 3 days 4 hours"
        )
        XCTAssertEqual(
            GitLabTokenExpiry.timeLeftLabel(expiresAt: expires, now: expires.addingTimeInterval(-(7 * day + 2 * hour))),
            "Expires in 7 days 2 hours"
        )
        XCTAssertEqual(
            GitLabTokenExpiry.timeLeftLabel(expiresAt: expires, now: expires.addingTimeInterval(-(12 * day))),
            "Expires in 12 days"
        )
        XCTAssertEqual(
            GitLabTokenExpiry.timeLeftLabel(expiresAt: expires, now: expires.addingTimeInterval(-(5 * hour))),
            "Expires in 5 hours"
        )
        XCTAssertEqual(
            GitLabTokenExpiry.timeLeftLabel(expiresAt: expires, now: expires.addingTimeInterval(-90)),
            "Expires in 1 minute"
        )
        XCTAssertEqual(GitLabTokenExpiry.timeLeftLabel(expiresAt: nil, now: expires), "Does not expire")
        XCTAssertEqual(
            GitLabTokenExpiry.timeLeftLabel(expiresAt: expires, now: expires.addingTimeInterval(30)),
            "Expired"
        )
        XCTAssertEqual(
            GitLabTokenExpiry.timeLeftLabel(expiresAt: expires, now: expires.addingTimeInterval(2 * day)),
            "Expired 2 days ago"
        )
    }

    func testBannerMessage() {
        let expires = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            GitLabTokenExpiry.bannerMessage(
                instanceLabel: "gitlab.com",
                expiresAt: expires,
                now: expires.addingTimeInterval(-(2 * day))
            ),
            "gitlab.com token expires in 2 days"
        )
        XCTAssertEqual(
            GitLabTokenExpiry.bannerMessage(
                instanceLabel: "gitlab.com",
                expiresAt: expires,
                now: expires.addingTimeInterval(10)
            ),
            "gitlab.com token has expired"
        )
    }

    private var day: TimeInterval { 24 * 60 * 60 }
    private var hour: TimeInterval { 60 * 60 }
}
