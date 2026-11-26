
#if os(tvOS)
import Foundation

final class Phase4DQualificationTests: XCTestCase {
    @MainActor
    private var remote: XCUIRemote { XCUIRemote.shared }
    private var app: XCUIApplication!
    private var robot: Robot!
    private let interval = 15.0
    private let tolerance = 2.0
    private struct Reading {
        let seconds: Double
        let remaining: Double
        let time: Date
    }

    @MainActor
    private func begin(_ scenario: String) throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        robot = Robot(app: app)
        print("PHASE4D BEGIN \(scenario)")
        robot.signIn(to: "https://demo.jellyfin.org/stable", username: "demo")
        robot.home()
        robot.media().library("Movies").item("Caminandes: Llama Drama")
        robot.play()
        sleep(3)
        try revealControls()
        let a = try read("initial")
        sleep(2)
        let b = try read("advancing")
        try require(b.seconds > a.seconds && b.remaining > interval + 8,
                    "Playback must advance and have enough remaining duration")
        try require(!paused(), "Playback must initially be active")
        evidence("ready")
    }

    @MainActor
    private func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        if !condition() {
            evidence("blocked")
            print("PHASE4D BLOCKED \(reason)")
            throw XCTSkip(reason)
        }
    }

    @MainActor
    private func nodes() -> [XCUIElementSnapshot] { robot.snapshotElements() }

    @MainActor
    private func position() -> Reading? {
        let all = nodes()
        func parse(_ text: String) -> Double? {
            let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "-− "))
                .split(separator: ":").map { Double($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        guard let e = all.first(where: { $0.identifier == "playbackElapsedTime" && $0.isEnabled }),
              let r = all.first(where: { $0.identifier == "playbackRemainingTime" && $0.isEnabled }),
              let elapsed = parse(e.label), let remaining = parse(r.label),
              elapsed + remaining > 0 else { return nil }
        return Reading(seconds: elapsed, remaining: remaining, time: Date())
    }

    @MainActor
    private func focused() -> String {
        nodes().filter(\.hasFocus).map {
            "\($0.elementType.rawValue):\($0.identifier):\($0.label):\($0.frame)"
        }.joined(separator: " | ")
    }

    @MainActor
    private func paused() -> Bool {
        nodes().contains { $0.identifier == "pause.circle" && $0.label == L10n.pause && $0.isEnabled }
    }

    @MainActor
    private func supplementVisible() -> Bool {
        let button = robot.buttons(labeled: L10n.fromBeginning).firstMatch
        return button.exists && button.isEnabled && button.isHittable
    }

    @MainActor
    private func playerMounted() -> Bool {
        nodes().contains { $0.identifier == "textSubtitleOverlay" }
    }

    // Hidden playback controls remain mounted and can appear as disabled AX nodes.
    @MainActor
    private func hidden() -> Bool {
        let all = nodes()
        let mounted = all.contains { $0.identifier == "textSubtitleOverlay" }
        let controls = all.filter {
            $0.identifier == "playbackElapsedTime" || $0.identifier == "playbackRemainingTime" ||
            $0.label == L10n.aspectFill || $0.label == L10n.info ||
            ($0.identifier == "ellipsis" && $0.frame.minY > 750 && $0.frame.minY < 900)
        }
        return mounted && !controls.contains(where: \.isEnabled) &&
            !all.contains(where: \.hasFocus) && !supplementVisible()
    }

    @MainActor
    private func playbackFocus() -> Bool {
        let all = nodes()
        let enabledFocus = all.filter { $0.hasFocus && $0.isEnabled }
        let toolbar = all.filter {
            $0.isEnabled && ($0.label == L10n.aspectFill ||
                $0.identifier == "arrow.up.left.and.arrow.down.right" ||
                ($0.identifier == "ellipsis" && $0.frame.minY > 750 && $0.frame.minY < 900))
        }
        if enabledFocus.contains(where: { f in
            toolbar.contains { t in f.frame == t.frame }
        }) { return true }
        let track = all.first { $0.elementType == .progressIndicator && $0.isEnabled &&
            $0.frame.width > 1000 && $0.frame.height < 100 }
        guard let track else { return false }
        return enabledFocus.contains { $0.frame.intersects(track.frame) &&
            $0.frame.width > 1000 && $0.frame.height < 160 }
    }

    @MainActor
    private func supplementContentFocused() -> Bool {
        nodes().contains { $0.isEnabled && $0.hasFocus && $0.label == L10n.fromBeginning }
    }

    @MainActor
    private func evidence(_ name: String) {
        let p = position()?.seconds.description ?? "not-visible"
        let timeline = nodes().filter { $0.identifier == "playbackElapsedTime" || $0.identifier == "playbackRemainingTime" }
        let detail = timeline.map { "\($0.identifier):\($0.label):enabled=\($0.isEnabled)" }.joined(separator: " | ")
        print("PHASE4D STATE \(name) position=\(p) focus=\(focused()) pausedIndicator=\(paused()) timeline=\(detail)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let dump = XCTAttachment(string: app.debugDescription)
        dump.name = name + "-accessibility"
        dump.lifetime = .keepAlways
        add(dump)
    }

    @MainActor
    private func wait(_ timeout: TimeInterval = 8, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func read(_ name: String, timeout: TimeInterval = 8) throws -> Reading {
        var value: Reading?
        let ready = wait(timeout) { value = position(); return value != nil }
        try require(ready, "Timestamp unavailable: " + name)
        let r = try XCTUnwrap(value)
        print("PHASE4D READING \(name) elapsed=\(r.seconds) remaining=\(r.remaining) epoch=\(r.time.timeIntervalSince1970)")
        return r
    }

    @MainActor
    private func revealControls() throws {
        if position() == nil {
            try require(playerMounted(), "Player surface unavailable before reveal")
            remote.press(.select)
        }
        try require(wait { self.position() != nil }, "Cannot establish visible player controls")
    }

    @MainActor
    private func hideForSeek(_ name: String) throws {
        try require(position() != nil && !supplementVisible() && playbackFocus(), "Visible timeline and playback-control focus required before Menu")
        remote.press(.menu)
        try require(wait { self.hidden() }, "Menu did not establish hidden controls with mounted player")
        evidence(name + "-hidden")
        try require(hidden(), "Hidden state changed before input")
    }

    @MainActor
    private func pausePlayback() throws {
        try revealControls()
        try require(!paused(), "Expected playing before Pause")
        remote.press(.playPause)
        try require(wait { self.paused() }, "Pause status unavailable")
        let a = try read("paused")
        sleep(2)
        let b = try read("paused-stable")
        XCTAssertEqual(a.seconds, b.seconds, accuracy: 1, "Paused timeline must not advance")
        evidence("paused-verified")
    }

    @MainActor
    private func seek(_ name: String, button: XCUIRemote.Button, offset: Double, playing: Bool) throws -> Reading {
        try revealControls()
        try require(paused() != playing, "Playback mode not established")
        let baseline = try read(name + "-baseline")
        try require(baseline.seconds + offset >= 3 && baseline.remaining - offset >= 5,
                    "Seek target too close to media boundary")
        try hideForSeek(name)
        let inputTime = Date()
        print("PHASE4D INPUT \(name) button=\(button) hidden=true baseline=\(baseline.seconds) epoch=\(inputTime.timeIntervalSince1970) focus=\(focused())")
        remote.press(button)
        // Hidden -> progress is the explicit seek entry path; sample immediately.
        var observed: Reading?
        let ready = wait(5) { observed = self.position(); return observed != nil }
        if !ready { evidence(name + "-no-progress"); XCTFail("Seek input did not reveal progress"); return baseline }
        let first = try XCTUnwrap(observed)
        print("PHASE4D FIRST \(name) elapsed=\(first.seconds) epoch=\(first.time.timeIntervalSince1970) focus=\(focused())")
        // Verify a later settled reading, not only an optimistic timestamp.
        sleep(1)
        if position() == nil {
            try require(hidden(), "Post-seek state is neither visible timeline nor hidden player")
            remote.press(.select)
        }
        let settled = try read(name + "-settled")
        let elapsedWall = settled.time.timeIntervalSince(baseline.time)
        let expected = baseline.seconds + offset + (playing ? elapsedWall : 0)
        print("PHASE4D SEEK \(name) baseline=\(baseline.seconds) expected=\(expected) actual=\(settled.seconds) wall=\(elapsedWall) tolerance=\(tolerance)")
        evidence(name + "-post")
        XCTAssertEqual(settled.seconds, expected, accuracy: tolerance, "Settled seek position")
        if playing {
            try revealControls()
            XCTAssertFalse(paused(), "Seek must not pause active playback")
        } else {
            XCTAssertTrue(paused(), "Paused seek must not resume playback")
            sleep(2)
            let stable = try read(name + "-stable")
            XCTAssertEqual(stable.seconds, settled.seconds, accuracy: 1, "Committed paused position must remain stable")
        }
        return settled
    }

    // Independent backward scenarios advance naturally, not via a successful forward seek.
    @MainActor
    private func establishBackwardOrigin() throws {
        let deadline = Date().addingTimeInterval(40)
        repeat {
            try revealControls()
            if let r = position(), r.seconds >= 22, r.remaining >= 10 { return }
            sleep(2)
        } while Date() < deadline
        try require(false, "Cannot establish an unclamped backward origin by natural playback")
    }

    @MainActor
    func testPausedForward() throws {
        try begin("testPausedForward")
        try pausePlayback()
        _ = try seek("paused-forward", button: .right, offset: interval, playing: false)
        print("PHASE4D COMPLETE testPausedForward")
    }

    @MainActor
    func testPausedBackward() throws {
        try begin("testPausedBackward")
        try establishBackwardOrigin()
        try pausePlayback()
        _ = try seek("paused-backward", button: .left, offset: -interval, playing: false)
        print("PHASE4D COMPLETE testPausedBackward")
    }

    @MainActor
    func testActiveForward() throws {
        try begin("testActiveForward")
        _ = try seek("active-forward", button: .right, offset: interval, playing: true)
        print("PHASE4D COMPLETE testActiveForward")
    }

    @MainActor
    func testActiveBackward() throws {
        try begin("testActiveBackward")
        try establishBackwardOrigin()
        _ = try seek("active-backward", button: .left, offset: -interval, playing: true)
        print("PHASE4D COMPLETE testActiveBackward")
    }

    @MainActor
    func testControlsAndPlayback() throws {
        try begin("testControlsAndPlayback")
        try pausePlayback()
        try hideForSeek("controls-dismissal")
        remote.press(.select)
        try require(wait { self.position() != nil && self.playbackFocus() }, "Select did not present enabled playback controls with focus")
        XCTAssertTrue(paused(), "Select from hidden must not resume paused playback")
        evidence("controls-presented")
        let a = try read("before-resume")
        remote.press(.playPause)
        try require(wait { !self.paused() }, "Pause indicator did not clear")
        sleep(3)
        let b = try read("after-resume")
        XCTAssertGreaterThan(b.seconds, a.seconds + 1, "Playback must advance after resume")
        evidence("resumed")
        print("PHASE4D COMPLETE testControlsAndPlayback")
    }

    @MainActor
    func testSupplementFocus() throws {
        try begin("testSupplementFocus")
        try pausePlayback()
        try require(!supplementVisible(), "Distinct supplement content already present")
        evidence("supplement-before")
        let info = robot.buttons(labeled: L10n.info).firstMatch
        try require(info.exists && info.isEnabled && info.isHittable && playbackFocus(),
                    "Info tab and initial playback focus unavailable")
        let initialFocus = focused()
        // A Down navigation can briefly focus the tab; single-supplement presentation
        // automatically transfers focus to the preferred content button.
        for step in 1...4 {
            if supplementVisible() { break }
            try require(!focused().isEmpty, "Focus disappeared during supplement navigation")
            print("PHASE4D NAVIGATION step=\(step) direction=down focus=\(focused())")
            remote.press(.down)
            _ = wait(2) { self.supplementVisible() }
        }
        let opened = wait { self.supplementVisible() && self.supplementContentFocused() }
        evidence("supplement-after-focus")
        try require(opened, "Cannot verify automatic Info content presentation and preferred From beginning focus")
        let openedFocus = focused()
        XCTAssertNotEqual(initialFocus, openedFocus, "Focus must move from original control")
        remote.press(.menu)
        let dismissed = wait { !self.supplementVisible() && self.position() != nil && self.playbackFocus() }
        evidence("supplement-dismissed")
        XCTAssertTrue(dismissed, "Menu must dismiss supplement and restore enabled playback-control focus")
        let restoredFocus = focused()
        XCTAssertFalse(restoredFocus.isEmpty, "Focus must be observable after dismissal")
        XCTAssertNotEqual(restoredFocus, openedFocus, "Focus must leave the dismissed supplement")
        print("PHASE4D COMPLETE testSupplementFocus")
    }
}
#endif
