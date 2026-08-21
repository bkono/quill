import Darwin
import Testing
@testable import quill

@Suite
struct MeetingCandidateResolverTests {
    @Test
    func testOutputOnlyActivityDoesNotCreateCandidate() {
        let candidate = MeetingCandidateResolver.resolve([
            activity(
                pid: 100,
                bundleID: "us.zoom.xos",
                input: false,
                output: true
            ),
        ])

        #expect(candidate == nil)
    }

    @Test
    func testZoomInputCreatesCandidate() throws {
        let candidate = try #require(MeetingCandidateResolver.resolve([
            activity(
                pid: 101,
                bundleID: "us.zoom.xos.CptHost",
                input: true,
                output: false
            ),
        ]))

        #expect(candidate.key == "zoom")
        #expect(candidate.displayName == "Zoom")
        #expect(candidate.sourcePID == 101)
        #expect(candidate.confirmationDelay == 3)
    }

    @Test
    func testSlackRequiresFullDuplexAcrossItsProcessFamily() throws {
        #expect(MeetingCandidateResolver.resolve([
            activity(
                pid: 201,
                bundleID: "com.tinyspeck.slackmacgap.helper",
                input: true,
                output: false
            ),
        ]) == nil)

        let candidate = try #require(MeetingCandidateResolver.resolve([
            activity(
                pid: 201,
                bundleID: "com.tinyspeck.slackmacgap.helper",
                input: true,
                output: false
            ),
            activity(
                pid: 202,
                bundleID: "com.tinyspeck.slackmacgap.renderer",
                input: false,
                output: true
            ),
        ]))

        #expect(candidate.key == "slack")
        #expect(candidate.sourcePID == 201)
        #expect(candidate.confirmationDelay == 5)
    }

    @Test
    func testBrowserHelperProcessResolvesToGenericBrowserCandidate() throws {
        let candidate = try #require(MeetingCandidateResolver.resolve([
            activity(
                pid: 301,
                bundleID: "com.google.Chrome.helper.renderer",
                input: true,
                output: true
            ),
        ]))

        #expect(candidate.key == "chrome")
        #expect(candidate.displayName == "Chrome")
        #expect(candidate.sourceBundleID == "com.google.Chrome")
    }

    @Test
    func testDedicatedMeetingClientWinsOverBrowser() throws {
        let candidate = try #require(MeetingCandidateResolver.resolve([
            activity(
                pid: 401,
                bundleID: "com.google.Chrome",
                input: true,
                output: true
            ),
            activity(
                pid: 402,
                bundleID: "com.microsoft.teams2",
                input: true,
                output: true
            ),
        ]))

        #expect(candidate.key == "teams")
        #expect(candidate.sourcePID == 402)
    }

    private func activity(
        pid: pid_t,
        bundleID: String,
        input: Bool,
        output: Bool
    ) -> AudioProcessActivity {
        AudioProcessActivity(
            pid: pid,
            bundleID: bundleID,
            appName: bundleID,
            isRunningInput: input,
            isRunningOutput: output
        )
    }
}
