//
//  Bundle+Version.swift
//  MergeRequestMonitor
//

import Foundation

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    var appDisplayName: String {
        (infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (infoDictionary?["CFBundleName"] as? String)
            ?? menuProductName
    }

    var feedbackURL: URL {
        let components = URLComponents(string: "https://www.georgegillams.co.uk/merge-request-monitor-feedback")!
        return components.url!
    }

    var authorURL: URL {
        var components = URLComponents(string: "https://www.georgegillams.co.uk/")!
        components.queryItems = [URLQueryItem(name: "utm_source", value: "merge-request-monitor")]
        return components.url!
    }

    var isLocalDevelopment: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var menuProductName: String {
        "Merge Request Monitor"
    }

    var menuBuildLabel: String {
        isLocalDevelopment ? "local development" : appVersion
    }
}
