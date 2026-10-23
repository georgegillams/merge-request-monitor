//
//  GitLabAPIClient.swift
//  MergeRequestMonitor
//

import Foundation

enum GitLabAPIError: LocalizedError {
    case invalidURL
    case httpStatus(Int, String?)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid GitLab URL"
        case .httpStatus(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body)"
            }
            return "HTTP \(code)"
        case .decoding(let error):
            return "Could not parse response: \(error.localizedDescription)"
        }
    }
}

actor GitLabAPIClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Ephemeral session: GitLab responses stay in memory. The delegate refuses any
        // redirect whose host is not the host we originally requested.
        self.session = URLSession(
            configuration: configuration,
            delegate: GitLabSameHostRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// Authored open MRs, and optionally authored MRs merged in the last 12 hours.
    func fetchAuthoredMergeRequests(
        instance: GitLabInstanceConfig,
        token: String,
        sortOrder: MergeRequestSortOrder,
        includeRecentlyMerged: Bool
    ) async throws -> [MergeRequestItem] {
        async let openMRs = listMergeRequests(
            baseURL: instance.normalizedBaseURL,
            token: token,
            state: "opened",
            sortOrder: sortOrder
        )
        let open = try await openMRs
        let merged: [APIMergeRequest]
        if includeRecentlyMerged {
            merged = try await listRecentlyMergedMergeRequests(
                baseURL: instance.normalizedBaseURL,
                token: token
            )
        } else {
            merged = []
        }
        let defaultBranches = await fetchDefaultBranches(
            baseURL: instance.normalizedBaseURL,
            projectIDs: Set((open + merged).map(\.targetProjectID)),
            token: token
        )
        var results: [MergeRequestItem] = []

        try await withThrowingTaskGroup(of: MergeRequestItem?.self) { group in
            for mr in open {
                group.addTask {
                    try await self.enrichOpen(
                        mr: mr,
                        instance: instance,
                        token: token,
                        defaultBranch: defaultBranches[mr.targetProjectID] ?? ""
                    )
                }
            }
            for mr in merged {
                group.addTask {
                    await Optional(self.makeMergedItem(
                        mr: mr,
                        instance: instance,
                        defaultBranch: defaultBranches[mr.targetProjectID] ?? ""
                    ))
                }
            }
            for try await item in group {
                if let item {
                    results.append(item)
                }
            }
        }

        return results.sorted {
            if $0.projectPath == $1.projectPath {
                return $0.iid > $1.iid
            }
            return $0.projectPath.localizedCaseInsensitiveCompare($1.projectPath) == .orderedAscending
        }
    }

    // MARK: - Private

    private static let recentlyMergedWindow: TimeInterval = 12 * 60 * 60

    private struct APIMergeRequest: Decodable {
        let id: Int
        let iid: Int
        let title: String
        let web_url: String?
        let created_at: String?
        let updated_at: String?
        let merged_at: String?
        let project_id: Int
        let target_project_id: Int?
        let source_branch: String?
        let target_branch: String?
        let references: References?
        let head_pipeline: PipelineRef?
        let pipeline: PipelineRef?

        struct References: Decodable {
            let full: String?
        }

        struct PipelineRef: Decodable {
            let id: Int?
            let project_id: Int?
            let status: String?
        }

        var pipelineID: Int? {
            head_pipeline?.id ?? pipeline?.id
        }

        var projectPath: String {
            if let full = references?.full, let bang = full.firstIndex(of: "!") {
                return String(full[..<bang])
            }
            return "project/\(project_id)"
        }

        /// Project the MR merges into. Forks keep `project_id` as the source.
        var targetProjectID: Int {
            target_project_id ?? project_id
        }
    }

    private struct APIPipeline: Decodable {
        let id: Int
        let project_id: Int?
    }

    private struct APIJob: Decodable {
        let id: Int
        let name: String
        let stage: String
        let status: String
        let web_url: String?
    }

    private struct APIApprovals: Decodable {
        let approved_by: [ApproverWrapper]?
        let approvals_required: Int?
        let approvals_left: Int?
        let user_has_approved: Bool?

        struct ApproverWrapper: Decodable {
            let user: ApproverUser?
        }

        struct ApproverUser: Decodable {
            let name: String?
            let username: String?
        }
    }

    private func listMergeRequests(
        baseURL: String,
        token: String,
        state: String,
        sortOrder: MergeRequestSortOrder
    ) async throws -> [APIMergeRequest] {
        guard var components = URLComponents(string: "\(baseURL)/api/v4/merge_requests") else {
            throw GitLabAPIError.invalidURL
        }
        // The page is capped at 50, so the query field and direction have to match the setting.
        components.queryItems = [
            URLQueryItem(name: "scope", value: "created_by_me"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "order_by", value: sortOrder.gitLabOrderBy),
            URLQueryItem(name: "sort", value: sortOrder.gitLabSort)
        ]
        guard let url = components.url else { throw GitLabAPIError.invalidURL }
        return try await get(url, baseURL: baseURL, token: token)
    }

    private func listRecentlyMergedMergeRequests(
        baseURL: String,
        token: String
    ) async throws -> [APIMergeRequest] {
        let cutoff = Date().addingTimeInterval(-Self.recentlyMergedWindow)
        guard var components = URLComponents(string: "\(baseURL)/api/v4/merge_requests") else {
            throw GitLabAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "scope", value: "created_by_me"),
            URLQueryItem(name: "state", value: "merged"),
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "order_by", value: "merged_at"),
            URLQueryItem(name: "sort", value: "desc"),
            URLQueryItem(name: "merged_after", value: Self.formatGitLabDate(cutoff))
        ]
        guard let url = components.url else { throw GitLabAPIError.invalidURL }
        let mrs: [APIMergeRequest] = try await get(url, baseURL: baseURL, token: token)
        // Keep a client-side floor in case an older GitLab ignores `merged_after`.
        return mrs.filter { Self.parseGitLabDate($0.merged_at) >= cutoff }
    }

    private func enrichOpen(
        mr: APIMergeRequest,
        instance: GitLabInstanceConfig,
        token: String,
        defaultBranch: String
    ) async throws -> MergeRequestItem {
        async let stages = fetchStages(
            baseURL: instance.normalizedBaseURL,
            mr: mr,
            token: token
        )
        async let approvals = fetchApprovals(
            baseURL: instance.normalizedBaseURL,
            projectID: mr.project_id,
            iid: mr.iid,
            token: token
        )
        async let threads = fetchThreads(
            baseURL: instance.normalizedBaseURL,
            mergeRequestID: mr.id,
            projectID: mr.project_id,
            iid: mr.iid,
            token: token
        )
        async let isInMergeTrain = fetchIsInMergeTrain(
            baseURL: instance.normalizedBaseURL,
            projectID: mr.project_id,
            iid: mr.iid,
            token: token
        )

        return MergeRequestItem(
            id: "\(instance.id.uuidString)-\(mr.id)",
            instanceID: instance.id,
            instanceLabel: instance.displayLabel,
            projectID: mr.project_id,
            iid: mr.iid,
            title: mr.title,
            projectPath: mr.projectPath,
            webURL: sameHostURL(mr.web_url, baseURL: instance.normalizedBaseURL),
            sourceBranch: mr.source_branch ?? "",
            targetBranch: mr.target_branch ?? "",
            defaultBranch: defaultBranch,
            stages: try await stages,
            approvals: try await approvals,
            threads: await threads,
            mergeIndicator: await isInMergeTrain ? .mergeTrain : .none,
            mergedAt: nil,
            createdAt: Self.parseGitLabDate(mr.created_at),
            updatedAt: Self.parseGitLabDate(mr.updated_at)
        )
    }

    /// Recently merged rows only need identity and the solid merge mark.
    private func makeMergedItem(
        mr: APIMergeRequest,
        instance: GitLabInstanceConfig,
        defaultBranch: String
    ) -> MergeRequestItem {
        let mergedAt = Self.parseGitLabDate(mr.merged_at)
        return MergeRequestItem(
            id: "\(instance.id.uuidString)-\(mr.id)",
            instanceID: instance.id,
            instanceLabel: instance.displayLabel,
            projectID: mr.project_id,
            iid: mr.iid,
            title: mr.title,
            projectPath: mr.projectPath,
            webURL: sameHostURL(mr.web_url, baseURL: instance.normalizedBaseURL),
            sourceBranch: mr.source_branch ?? "",
            targetBranch: mr.target_branch ?? "",
            defaultBranch: defaultBranch,
            stages: [],
            approvals: ApprovalSummary(
                approvedBy: [],
                approvalsRequired: nil,
                approvalsLeft: nil,
                userHasApproved: false
            ),
            threads: .empty,
            mergeIndicator: .merged,
            mergedAt: mergedAt == .distantPast ? nil : mergedAt,
            createdAt: Self.parseGitLabDate(mr.created_at),
            updatedAt: Self.parseGitLabDate(mr.updated_at)
        )
    }

    private struct APIProject: Decodable {
        let default_branch: String?
    }

    /// One request per distinct target project. Failures leave that project unnamed
    /// so stacking still works from source/target links alone.
    private func fetchDefaultBranches(
        baseURL: String,
        projectIDs: Set<Int>,
        token: String
    ) async -> [Int: String] {
        var result: [Int: String] = [:]
        await withTaskGroup(of: (Int, String?).self) { group in
            for projectID in projectIDs {
                group.addTask {
                    (projectID, await self.fetchDefaultBranch(
                        baseURL: baseURL,
                        projectID: projectID,
                        token: token
                    ))
                }
            }
            for await (projectID, branch) in group {
                if let branch {
                    result[projectID] = branch
                }
            }
        }
        return result
    }

    private func fetchDefaultBranch(
        baseURL: String,
        projectID: Int,
        token: String
    ) async -> String? {
        let url: URL
        do {
            url = try apiURL(baseURL, path: "/api/v4/projects/\(projectID)")
        } catch {
            return nil
        }
        do {
            let project: APIProject = try await get(url, baseURL: baseURL, token: token)
            let branch = project.default_branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return branch.isEmpty ? nil : branch
        } catch {
            gDebugPrint("default branch failed for project \(projectID):", error.localizedDescription)
            return nil
        }
    }

    private struct ResolvedPipeline {
        let id: Int
        let projectID: Int
    }

    private func fetchStages(
        baseURL: String,
        mr: APIMergeRequest,
        token: String
    ) async throws -> [PipelineStage] {
        guard let pipeline = try await resolvePipeline(baseURL: baseURL, mr: mr, token: token) else {
            return []
        }
        let jobs = try await fetchJobs(
            baseURL: baseURL,
            projectID: pipeline.projectID,
            pipelineID: pipeline.id,
            token: token
        )
        let reported = await reportedStages(
            baseURL: baseURL,
            fullPath: mr.projectPath,
            projectID: mr.project_id,
            pipelineID: pipeline.id,
            token: token
        )
        return stages(from: jobs, reported: reported, baseURL: baseURL)
    }

    /// The merge request list often omits `head_pipeline`. Approvals still load
    /// from the project id and iid; stages need a pipeline, so ask for this MR's pipelines.
    private func resolvePipeline(
        baseURL: String,
        mr: APIMergeRequest,
        token: String
    ) async throws -> ResolvedPipeline? {
        if let id = mr.pipelineID {
            let projectID = mr.head_pipeline?.project_id ?? mr.pipeline?.project_id ?? mr.project_id
            return ResolvedPipeline(id: id, projectID: projectID)
        }

        guard var components = URLComponents(
            string: "\(baseURL)/api/v4/projects/\(mr.project_id)/merge_requests/\(mr.iid)/pipelines"
        ) else {
            throw GitLabAPIError.invalidURL
        }
        // Newest pipeline is first. One result is enough for the current head.
        components.queryItems = [URLQueryItem(name: "per_page", value: "1")]
        guard let url = components.url else { throw GitLabAPIError.invalidURL }
        let pipelines: [APIPipeline]
        do {
            pipelines = try await get(url, baseURL: baseURL, token: token)
        } catch let error as GitLabAPIError {
            // Pipelines aren't available for this MR. Leave its stages empty.
            if case .httpStatus(let code, _) = error, code == 403 || code == 404 {
                return nil
            }
            throw error
        }
        guard let latest = pipelines.max(by: { $0.id < $1.id }) else { return nil }
        return ResolvedPipeline(id: latest.id, projectID: latest.project_id ?? mr.project_id)
    }

    private func fetchJobs(
        baseURL: String,
        projectID: Int,
        pipelineID: Int,
        token: String
    ) async throws -> [APIJob] {
        var page = 1
        var collected: [APIJob] = []
        // The jobs API defaults to 20 per page, newest first. A pipeline with more
        // jobs than that would drop earlier stages.
        for _ in 0..<15 {
            guard var components = URLComponents(
                string: "\(baseURL)/api/v4/projects/\(projectID)/pipelines/\(pipelineID)/jobs"
            ) else {
                throw GitLabAPIError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "include_retried", value: "false"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]
            guard let url = components.url else { throw GitLabAPIError.invalidURL }
            let pageResult: (value: [APIJob], nextPage: Int?) = try await fetch(url, baseURL: baseURL, token: token)
            collected.append(contentsOf: pageResult.value)
            guard let nextPage = pageResult.nextPage, nextPage > page else { break }
            page = nextPage
        }
        return collected
    }

    /// A stage GitLab has already summarized. Job ids are only a fallback order.
    private struct ReportedStage {
        let name: String
        let status: PipelineStageStatus
    }

    private func stages(from jobs: [APIJob], reported: [ReportedStage], baseURL: String) -> [PipelineStage] {
        var earliestJobID: [String: Int] = [:]
        var jobsByStage: [String: [PipelineJob]] = [:]

        // Retried attempts are omitted. The remaining jobs are the latest of each name.
        let orderedJobs = jobs.sorted { $0.id < $1.id }
        for job in orderedJobs {
            if earliestJobID[job.stage] == nil {
                earliestJobID[job.stage] = job.id
            }
            jobsByStage[job.stage, default: []].append(
                PipelineJob(
                    id: job.id,
                    name: job.name,
                    status: PipelineStageStatus.fromGitLabStatus(job.status),
                    webURL: sameHostURL(job.web_url, baseURL: baseURL)
                )
            )
        }

        var statusByName: [String: PipelineStageStatus] = [:]
        var names: [String] = []
        for stage in reported where statusByName[stage.name] == nil && jobsByStage[stage.name] != nil {
            statusByName[stage.name] = stage.status
            names.append(stage.name)
        }
        let missing = earliestJobID.keys.filter { statusByName[$0] == nil }.sorted {
            (earliestJobID[$0] ?? 0) < (earliestJobID[$1] ?? 0)
        }
        names.append(contentsOf: missing)

        return names.map { name in
            PipelineStage(
                name: name,
                status: statusByName[name] ?? .unknown,
                jobs: jobsByStage[name] ?? []
            )
        }
    }

    /// GitLab draws stages left to right by `ci_stages.position` and stores each stage's status.
    private static let stageStatusQuery = """
    query($fullPath: ID!, $id: CiPipelineID!) {
      project(fullPath: $fullPath) {
        pipeline(id: $id) {
          stages(first: 100) {
            nodes { name status }
          }
        }
      }
    }
    """

    private struct StageStatusResponse: Decodable {
        struct Envelope: Decodable {
            struct Project: Decodable {
                struct Pipeline: Decodable {
                    struct Stages: Decodable {
                        struct Node: Decodable {
                            let name: String?
                            let status: String?
                        }

                        let nodes: [Node]?
                    }

                    let stages: Stages?
                }

                let pipeline: Pipeline?
            }

            let project: Project?
        }

        let data: Envelope?
    }

    private func reportedStages(
        baseURL: String,
        fullPath: String,
        projectID: Int,
        pipelineID: Int,
        token: String
    ) async -> [ReportedStage] {
        // `project/<id>` is the stand-in used when the MR list has no path.
        guard fullPath != "project/\(projectID)" else { return [] }
        guard let url = URL(string: baseURL + "/api/graphql") else { return [] }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "query": Self.stageStatusQuery,
                "variables": [
                    "fullPath": fullPath,
                    "id": "gid://gitlab/Ci::Pipeline/\(pipelineID)"
                ]
            ])
        } catch {
            return []
        }

        do {
            let response: StageStatusResponse = try await fetch(
                url,
                baseURL: baseURL,
                token: token,
                method: "POST",
                body: body
            ).value
            let nodes = response.data?.project?.pipeline?.stages?.nodes ?? []
            return nodes.compactMap { node in
                guard let name = node.name, !name.isEmpty else { return nil }
                return ReportedStage(name: name, status: PipelineStageStatus.fromGitLabStatus(node.status))
            }
        } catch {
            return []
        }
    }

    private struct APIMergeTrainCar: Decodable {
        let status: String?
    }

    /// Active and still-merging cars count as "on the train". Completed cars do not.
    private static let activeMergeTrainStatuses: Set<String> = [
        "idle", "fresh", "stale", "merging"
    ]

    /// Soft-fails when merge trains are unavailable (CE/Free, missing feature, or 404).
    private func fetchIsInMergeTrain(
        baseURL: String,
        projectID: Int,
        iid: Int,
        token: String
    ) async -> Bool {
        let url: URL
        do {
            url = try apiURL(
                baseURL,
                path: "/api/v4/projects/\(projectID)/merge_trains/merge_requests/\(iid)"
            )
        } catch {
            return false
        }
        do {
            let car: APIMergeTrainCar = try await get(url, baseURL: baseURL, token: token)
            let status = (car.status ?? "").lowercased()
            return Self.activeMergeTrainStatuses.contains(status)
        } catch {
            return false
        }
    }

    private func fetchApprovals(
        baseURL: String,
        projectID: Int,
        iid: Int,
        token: String
    ) async throws -> ApprovalSummary {
        let url = try apiURL(
            baseURL,
            path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/approvals"
        )
        do {
            let response: APIApprovals = try await get(url, baseURL: baseURL, token: token)
            let names = (response.approved_by ?? []).compactMap { wrapper -> String? in
                wrapper.user?.name ?? wrapper.user?.username
            }
            return ApprovalSummary(
                approvedBy: names,
                approvalsRequired: response.approvals_required,
                approvalsLeft: response.approvals_left,
                userHasApproved: response.user_has_approved ?? false
            )
        } catch {
            // Approvals API may be unavailable on some Free/CE setups.
            return ApprovalSummary(
                approvedBy: [],
                approvalsRequired: nil,
                approvalsLeft: nil,
                userHasApproved: false
            )
        }
    }

    private static let threadCountsQuery = """
    query($id: MergeRequestID!) {
      mergeRequest(id: $id) {
        resolvableDiscussionsCount
        resolvedDiscussionsCount
      }
    }
    """

    private struct ThreadCountsResponse: Decodable {
        struct Envelope: Decodable {
            struct MergeRequest: Decodable {
                let resolvableDiscussionsCount: Int?
                let resolvedDiscussionsCount: Int?
            }

            let mergeRequest: MergeRequest?
        }

        let data: Envelope?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        let message: String?
    }

    /// Discussion-level resolution flags from the REST discussions API.
    /// Prefer these over note fields: replies are not resolvable, and the root note
    /// is not always first in the payload the client receives.
    private struct APIDiscussion: Decodable {
        let resolvable: Bool?
        let resolved: Bool?
    }

    /// Prefer GraphQL counts by global MR id; fall back to paging discussions.
    private func fetchThreads(
        baseURL: String,
        mergeRequestID: Int,
        projectID: Int,
        iid: Int,
        token: String
    ) async -> ThreadSummary {
        if let fromGraphQL = await threadCountsFromGraphQL(
            baseURL: baseURL,
            mergeRequestID: mergeRequestID,
            token: token
        ) {
            return fromGraphQL
        }
        return await threadCountsFromDiscussions(
            baseURL: baseURL,
            projectID: projectID,
            iid: iid,
            token: token
        )
    }

    private func threadCountsFromGraphQL(
        baseURL: String,
        mergeRequestID: Int,
        token: String
    ) async -> ThreadSummary? {
        guard let url = URL(string: baseURL + "/api/graphql") else { return nil }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "query": Self.threadCountsQuery,
                "variables": [
                    "id": "gid://gitlab/MergeRequest/\(mergeRequestID)"
                ]
            ])
        } catch {
            return nil
        }

        do {
            let response: ThreadCountsResponse = try await fetch(
                url,
                baseURL: baseURL,
                token: token,
                method: "POST",
                body: body
            ).value
            // Field-missing or auth errors still return HTTP 200 with an `errors` array.
            if let errors = response.errors, !errors.isEmpty {
                gDebugPrint(
                    "threadCounts GraphQL errors for MR \(mergeRequestID):",
                    errors.compactMap(\.message).joined(separator: "; ")
                )
                return nil
            }
            guard let mr = response.data?.mergeRequest,
                  let resolvable = mr.resolvableDiscussionsCount,
                  let resolved = mr.resolvedDiscussionsCount else {
                return nil
            }
            return ThreadSummary(
                resolvable: max(0, resolvable),
                resolved: min(max(0, resolved), max(0, resolvable))
            )
        } catch {
            gDebugPrint("threadCounts GraphQL failed for MR \(mergeRequestID):", error.localizedDescription)
            return nil
        }
    }

    private func threadCountsFromDiscussions(
        baseURL: String,
        projectID: Int,
        iid: Int,
        token: String
    ) async -> ThreadSummary {
        var page = 1
        var resolvable = 0
        var resolved = 0
        for _ in 0..<15 {
            guard var components = URLComponents(
                string: "\(baseURL)/api/v4/projects/\(projectID)/merge_requests/\(iid)/discussions"
            ) else {
                return .empty
            }
            components.queryItems = [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]
            guard let url = components.url else { return .empty }
            let pageResult: (value: [APIDiscussion], nextPage: Int?)
            do {
                pageResult = try await fetch(url, baseURL: baseURL, token: token)
            } catch {
                gDebugPrint(
                    "threadCounts discussions failed for \(projectID)!\(iid):",
                    error.localizedDescription
                )
                return .empty
            }
            for discussion in pageResult.value {
                guard discussion.resolvable == true else { continue }
                resolvable += 1
                if discussion.resolved == true {
                    resolved += 1
                }
            }
            guard let nextPage = pageResult.nextPage, nextPage > page else { break }
            page = nextPage
        }
        return ThreadSummary(resolvable: resolvable, resolved: resolved)
    }

    private static let gitLabDateFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()

    /// GitLab sends timestamps as ISO-8601, with or without fractional seconds.
    private static func parseGitLabDate(_ value: String?) -> Date {
        guard let value else { return .distantPast }
        for formatter in gitLabDateFormatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return .distantPast
    }

    private static func formatGitLabDate(_ date: Date) -> String {
        gitLabDateFormatters[1].string(from: date)
    }

    private func apiURL(_ baseURL: String, path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else {
            throw GitLabAPIError.invalidURL
        }
        return url
    }

    /// Keeps a GitLab `web_url` only when it points at the configured instance.
    private func sameHostURL(_ string: String?, baseURL: String) -> URL? {
        guard let string, let url = URL(string: string) else { return nil }
        guard let allowed = URL(string: baseURL)?.host,
              let host = url.host,
              host.caseInsensitiveCompare(allowed) == .orderedSame,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private func get<T: Decodable>(_ url: URL, baseURL: String, token: String) async throws -> T {
        try await fetch(url, baseURL: baseURL, token: token).value
    }

    private func fetch<T: Decodable>(
        _ url: URL,
        baseURL: String,
        token: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (value: T, nextPage: Int?) {
        guard let allowedHost = URL(string: baseURL)?.host,
              let host = url.host,
              host.caseInsensitiveCompare(allowedHost) == .orderedSame else {
            throw GitLabAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitLabAPIError.httpStatus(-1, nil)
        }
        guard let responseHost = http.url?.host,
              responseHost.caseInsensitiveCompare(allowedHost) == .orderedSame else {
            throw GitLabAPIError.invalidURL
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw GitLabAPIError.httpStatus(http.statusCode, body?.prefix(200).description)
        }
        let nextPage = http.value(forHTTPHeaderField: "X-Next-Page").flatMap(Int.init).flatMap { page in
            page > 0 ? page : nil
        }
        do {
            let value = try JSONDecoder().decode(T.self, from: data)
            return (value, nextPage)
        } catch {
            throw GitLabAPIError.decoding(error)
        }
    }
}

/// Refuses redirects that leave the GitLab host the request was sent to.
/// Returning nil makes URLSession deliver the redirect response instead of following it,
/// so the bearer token is not sent to any other host.
private final class GitLabSameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalHost = task.originalRequest?.url?.host
        let nextHost = request.url?.host
        guard let originalHost, let nextHost,
              originalHost.caseInsensitiveCompare(nextHost) == .orderedSame else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
