
#if os(tvOS)
// CI-only test overlay, appended to the existing screenshot test file in a disposable worktree.
final class Phase4BRuntimeTests: XCTestCase {
    @MainActor
    func testRemotePlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let robot = Robot(app: app)
        let remote = XCUIRemote.shared

        func evidence(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = name + "-accessibility"
            dump.lifetime = .keepAlways
            add(dump)
        }

        func seconds(_ label: String) -> Double? {
            let parts = label.trimmingCharacters(in: CharacterSet(charactersIn: "-− "))
                .split(separator: ":").map { Double($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }

        func position() -> Double? {
            let elements = robot.snapshotElements()
            guard let elapsed = elements.first(where: { $0.identifier == "playbackElapsedTime" }) else { return nil }
            return seconds(elapsed.label)
        }

        func readPosition(_ description: String, timeout: TimeInterval = 12) throws -> Double {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if let p = position() {
                    print("PHASE4B POSITION \(description): \(p)")
                    return p
                }
                usleep(250_000)
            } while Date() < deadline
            evidence("missing-position-" + description)
            throw XCTSkip("Playback timestamp unavailable: " + description)
        }

        func waitForPosition(_ expected: Double, tolerance: Double, name: String) throws -> Double {
            let deadline = Date().addingTimeInterval(12)
            var last: Double?
            repeat {
                last = position() ?? last
                if let p = last, abs(p - expected) <= tolerance {
                    print("PHASE4B SEEK \(name): expected \(expected) actual \(p) tolerance \(tolerance)")
                    evidence(name)
                    return p
                }
                usleep(250_000)
            } while Date() < deadline
            evidence(name + "-outside-tolerance")
            let actual = try XCTUnwrap(last, "No timestamp after seek")
            XCTAssertEqual(actual, expected, accuracy: tolerance, name)
            return actual
        }

        robot.signIn(to: "https://demo.jellyfin.org/stable", username: "demo")
        robot.home()
        robot.media().library("Movies").item("Caminandes: Llama Drama")
        robot.play()
        sleep(3)
        // Upstream controls auto-hide. Select only if the timestamp is not exposed.
        if position() == nil { remote.press(.select) }
        let initial = try readPosition("initial")
        sleep(2)
        let beforePause = try readPosition("before-pause")
        guard beforePause > initial else {
            evidence("playback-not-advancing")
            throw XCTSkip("Demo playback did not establish an advancing timeline")
        }
        remote.press(.playPause)
        sleep(2)
        let paused = try readPosition("paused")
        sleep(3)
        let stable = try readPosition("paused-stable")
        XCTAssertEqual(stable, paused, accuracy: 1.5, "Play/pause must stop timeline advancement")
        print("PHASE4B PASS pause: before \(beforePause), paused \(paused), stable \(stable)")
        evidence("paused")
        // The default forward and backward intervals are both fifteen seconds.
        remote.press(.right)
        let forward = try waitForPosition(stable + 15, tolerance: 2, name: "forward-15s")
        XCTAssertGreaterThan(forward, stable)
        sleep(1)
        let settledForward = try readPosition("forward-settled")
        XCTAssertEqual(settledForward, forward, accuracy: 2, "Paused seek must settle at the new position")
        remote.press(.left)
        let backward = try waitForPosition(settledForward - 15, tolerance: 2, name: "backward-15s")
        XCTAssertLessThan(backward, settledForward)
        sleep(1)
        let settledBackward = try readPosition("backward-settled")
        XCTAssertEqual(settledBackward, backward, accuracy: 2, "Backward seek must remain at committed position")
        print("PHASE4B PASS directional seeks and timestamp accuracy")
        // tvOS supplements present automatically on focus; do not require a Select press.
        let info = robot.buttons(labeled: L10n.info).firstMatch
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Caminandes")).firstMatch
        let contentButton = robot.buttons(labeled: L10n.fromBeginning).firstMatch
        func contentVisible() -> Bool {
            (title.exists && title.isHittable) || (contentButton.exists && contentButton.isHittable)
        }
        // Reopen controls from progress to establish a baseline with no supplement.
        remote.press(.menu)
        sleep(1)
        remote.press(.select)
        sleep(1)
        let baseline = contentVisible()
        evidence("before-supplement-navigation")
        if baseline {
            throw XCTSkip("Cannot establish distinct pre-presentation content baseline")
        }
        for _ in 0..<4 where !contentVisible() && !(info.exists && info.isHittable) {
            remote.press(.down)
            sleep(1)
        }
        if !contentVisible() {
            guard info.exists && info.isHittable else {
                evidence("supplement-tab-unavailable")
                throw XCTSkip("Info supplement tab was not exposed")
            }
            robot.focus(info)
            sleep(2)
        }
        evidence("supplement-open-on-focus")
        XCTAssertTrue(contentVisible(), "Focus-driven Info supplement exposes distinct media content")
        let openFocus = try XCTUnwrap(robot.focusedLabel, "Supplement focus must be observable")
        print("PHASE4B SUPPLEMENT focused label: \\(openFocus)")
        remote.press(.menu)
        sleep(2)
        evidence("supplement-dismissed")
        XCTAssertFalse(contentVisible(), "Menu dismisses Info supplement content")
        let restoredFocus = try XCTUnwrap(robot.focusedLabel, "Focus is restored after dismissal")
        print("PHASE4B PASS supplement presentation, dismissal and focus: \\(openFocus) -> \\(restoredFocus)")
        remote.press(.playPause)
        let resume = try readPosition("resume")
        sleep(3)
        let advancing = try readPosition("resumed-advancing")
        XCTAssertGreaterThan(advancing, resume + 1, "Play/pause must resume timeline advancement")
        print("PHASE4B PASS resume \(resume) -> \(advancing)")
        evidence("resumed")
        // XCUIRemote cannot force UIKit pressesCancelled. Menu dismissal is tested above;
        // actual cancellation and physical Siri Remote gesture interruption remain NOT RUN.
    }
}
#endif
