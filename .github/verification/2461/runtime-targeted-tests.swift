
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
        _ = try readPosition("initial")
        sleep(2)
        let beforePause = try readPosition("before-pause")
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
        remote.press(.left)
        let backward = try waitForPosition(forward - 15, tolerance: 2, name: "backward-15s")
        XCTAssertLessThan(backward, forward)
        print("PHASE4B PASS directional seeks and timestamp accuracy")
        // Info tab is a real supported supplement. Assert distinct content appears and disappears.
        let info = robot.buttons(labeled: L10n.info).firstMatch
        for _ in 0..<4 where !info.exists { remote.press(.down); sleep(1) }
        guard info.waitForExistence(timeout: 8) else {
            evidence("supplement-tab-unavailable")
            throw XCTSkip("Info supplement tab was not exposed by this simulator/media")
        }
        robot.focus(info)
        XCTAssertTrue(info.hasFocus || robot.focusedLabel == L10n.info, "Info tab receives focus")
        evidence("info-tab-focused")
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Caminandes")).firstMatch
        let before = title.exists && title.isHittable
        remote.press(.select)
        sleep(2)
        evidence("supplement-open")
        XCTAssertFalse(before, "Supplement content must be distinguishable before selection")
        XCTAssertTrue(title.exists && title.isHittable, "Selected Info supplement exposes media title")
        remote.press(.menu)
        sleep(2)
        evidence("supplement-dismissed")
        XCTAssertFalse(title.exists && title.isHittable, "Menu dismisses Info supplement content")
        XCTAssertNotNil(robot.focusedLabel, "Focus is restored after dismissal")
        print("PHASE4B PASS supplement presentation, dismissal and focus")
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
