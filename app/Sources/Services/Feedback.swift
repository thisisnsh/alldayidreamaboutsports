import AppKit

/// Pre-filled support emails, so users without a GitHub account can still
/// report. Build + OS go in the body so reports arrive with the version
/// already attached. Shared by Settings and the status item's right-click menu.
@MainActor
enum Feedback {
    static func reportBug() {
        AppAnalytics.bugReported()
        NSWorkspace.shared.open(supportMail(subject: "Bug report — All Day I Dream About Sports"))
    }

    static func requestFeature() {
        AppAnalytics.featureRequested()
        NSWorkspace.shared.open(supportMail(subject: "Feature request — All Day I Dream About Sports"))
    }

    private static func supportMail(subject: String) -> URL {
        let body = """


        ———
        \(AppEnvironment.profileName) \(AppEnvironment.appVersion) (Build \(AppEnvironment.buildNumber))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        func encode(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        return URL(string: "mailto:\(AppEnvironment.supportEmail)?subject=\(encode(subject))&body=\(encode(body))")!
    }
}
