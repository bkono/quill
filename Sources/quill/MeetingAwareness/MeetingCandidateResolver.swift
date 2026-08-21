import Darwin
import Foundation

/// One Core Audio client process and whether it currently owns active input or
/// output streams. This is metadata only; collecting it never opens an audio
/// stream or receives audio buffers.
struct AudioProcessActivity: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String
    let appName: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

/// A supported application whose observed media state is strong enough to be
/// treated as a meeting candidate.
struct MeetingCandidate: Equatable, Sendable {
    /// Stable across helper-process churn for one application family.
    let key: String
    let displayName: String
    let sourceBundleID: String
    let sourcePID: pid_t
    let confirmationDelay: TimeInterval
}

/// Converts raw HAL process activity into one deterministic application-level
/// candidate. Input/output from sibling helper processes is intentionally
/// aggregated before policy is evaluated.
enum MeetingCandidateResolver {
    private struct Definition {
        let key: String
        let displayName: String
        let canonicalBundleID: String
        let bundleIDs: [String]
        let requiresOutput: Bool
        let confirmationDelay: TimeInterval
    }

    // Dedicated meeting clients precede browsers so a browser kept warm in the
    // background does not mask a simultaneous native call.
    private static let definitions: [Definition] = [
        Definition(
            key: "zoom",
            displayName: "Zoom",
            canonicalBundleID: "us.zoom.xos",
            bundleIDs: ["us.zoom.xos", "us.zoom.ZoomPhone"],
            requiresOutput: false,
            confirmationDelay: 3
        ),
        Definition(
            key: "teams",
            displayName: "Teams",
            canonicalBundleID: "com.microsoft.teams2",
            bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
            requiresOutput: false,
            confirmationDelay: 3
        ),
        Definition(
            key: "webex",
            displayName: "Webex",
            canonicalBundleID: "com.cisco.webexmeetingsapp",
            bundleIDs: ["com.cisco.webexmeetingsapp", "com.webex.meetingmanager"],
            requiresOutput: false,
            confirmationDelay: 3
        ),
        // Slack may keep an input client warm while no huddle is active. Full
        // duplex activity is the conservative signal for v1.
        Definition(
            key: "slack",
            displayName: "Slack",
            canonicalBundleID: "com.tinyspeck.slackmacgap",
            bundleIDs: ["com.tinyspeck.slackmacgap"],
            requiresOutput: true,
            confirmationDelay: 5
        ),
        Definition(
            key: "chrome",
            displayName: "Chrome",
            canonicalBundleID: "com.google.Chrome",
            bundleIDs: ["com.google.Chrome"],
            requiresOutput: false,
            confirmationDelay: 3
        ),
        Definition(
            key: "brave",
            displayName: "Brave",
            canonicalBundleID: "com.brave.Browser",
            bundleIDs: ["com.brave.Browser"],
            requiresOutput: false,
            confirmationDelay: 3
        ),
        Definition(
            key: "arc",
            displayName: "Arc",
            canonicalBundleID: "company.thebrowser.Browser",
            bundleIDs: ["company.thebrowser.Browser"],
            requiresOutput: false,
            confirmationDelay: 3
        ),
        Definition(
            key: "edge",
            displayName: "Edge",
            canonicalBundleID: "com.microsoft.edgemac",
            bundleIDs: ["com.microsoft.edgemac"],
            requiresOutput: false,
            confirmationDelay: 3
        ),
        Definition(
            key: "safari",
            displayName: "Safari",
            canonicalBundleID: "com.apple.Safari",
            bundleIDs: ["com.apple.Safari"],
            requiresOutput: false,
            confirmationDelay: 3
        ),
    ]

    static func resolve(_ activities: [AudioProcessActivity]) -> MeetingCandidate? {
        for definition in definitions {
            let matching = activities.filter { activity in
                definition.bundleIDs.contains { bundleID in
                    matches(activity.bundleID, applicationBundleID: bundleID)
                }
            }

            guard let inputOwner = matching.first(where: \.isRunningInput) else { continue }
            guard !definition.requiresOutput
                || matching.contains(where: \.isRunningOutput)
            else { continue }

            return MeetingCandidate(
                key: definition.key,
                displayName: definition.displayName,
                sourceBundleID: definition.canonicalBundleID,
                sourcePID: inputOwner.pid,
                confirmationDelay: definition.confirmationDelay
            )
        }
        return nil
    }

    private static func matches(_ observedBundleID: String, applicationBundleID: String) -> Bool {
        let observed = observedBundleID.lowercased()
        let application = applicationBundleID.lowercased()
        return observed == application || observed.hasPrefix("\(application).")
    }
}
