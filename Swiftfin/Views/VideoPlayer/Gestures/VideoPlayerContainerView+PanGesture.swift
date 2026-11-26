//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import MediaPlayer
import SwiftUI
import UIKit

extension VideoPlayer.UIContainerViewController {

    func allowsDownwardPlaybackPan(_ gesture: UIPanGestureRecognizer) -> Bool {
        guard !viewState.isGestureLocked,
              !viewState.isPresentingControls,
              !viewState.isPresentingSupplement,
              let view = gesture.view,
              view.bounds.width > 0,
              playbackPanDirection(for: gesture.velocity(in: view)) == .down
        else { return false }

        let x = gesture.location(in: view).x / view.bounds.width
        switch verticalPanAction(at: x) {
        case .brightness, .volume:
            return true
        case .scrub, .slowScrub:
            return viewState.mediaSession?.canSeek == true && viewState.mediaSession?.item.runtime != nil
        case .none:
            return false
        }
    }

    private func playbackPanDirection(for velocity: CGPoint) -> Direction {
        // Prioritize horizontal detection just a bit more
        if velocity.y.magnitude < velocity.x.magnitude + 20 {
            return velocity.x > 0 ? .right : .left
        }

        return velocity.y > 0 ? .down : .up
    }

    private func verticalPanAction(at x: CGFloat) -> PanGestureAction {
        if x < 0.5 {
            Defaults[.VideoPlayer.Gesture.verticalPanLeftAction]
        } else {
            Defaults[.VideoPlayer.Gesture.verticalPanRightAction]
        }
    }

    func handlePanGesture(
        translation: CGPoint,
        velocity: CGPoint,
        location: CGPoint,
        unitPoint: UnitPoint,
        state: UIGestureRecognizer.State,
        identity: PanGestureIdentity
    ) {
        let isTerminal = state == .ended || state == .cancelled || state == .failed
        if state == .began {
            guard viewState.panHandlingIdentity == nil,
                  viewState.mediaSession != nil,
                  checkGestureLock() else { return }

            viewState.panHandlingIdentity = identity
        } else {
            guard viewState.panHandlingIdentity == identity else { return }
        }

        defer {
            if isTerminal, viewState.panHandlingIdentity == identity {
                viewState.resetPanHandling()
            }
        }

        guard state == .began || state == .changed || isTerminal else { return }

        let direction = playbackPanDirection(for: velocity)
        if state == .began {
            viewState.cancelTapGesture()
            viewState.setInteraction(.pan, active: true)

            if viewState.isPresentingSupplement {
                viewState.panHandlingOwner = .supplement
            } else if viewState.canPanZoom {
                viewState.panHandlingOwner = .zoom
            } else if Defaults[.VideoPlayer.Gesture.horizontalSwipeAction] != .none, direction.isHorizontal {
                viewState.panHandlingOwner = .swipe
            } else {
                viewState.panHandlingOwner = .action(
                    makePanHandlingAction(direction: direction, location: location, unitPoint: unitPoint)
                )
            }
        }

        // The initial route owns the entire gesture, including its terminal event.
        guard let owner = viewState.panHandlingOwner else { return }

        switch owner {
        case .supplement:
            handleSupplementPanAction(translation: translation, velocity: velocity.y, state: state)

        case .zoom:
            handleZoomPan(translation: translation, state: state)

        case .swipe:
            if state != .cancelled,
               state != .failed,
               direction.isHorizontal,
               !viewState.didSwipe,
               max(velocity.x.magnitude, velocity.y.magnitude) >= 1200,
               max(translation.x.magnitude, translation.y.magnitude) >= 80 {
                handleSwipeAction(direction: direction)
                viewState.didSwipe = true
            }

        case let .action(action):
            let handlingState: _PanHandlingState = .init(
                translation: translation,
                velocity: velocity,
                location: location,
                unitPoint: unitPoint,
                gestureState: state
            )
            unpackAndHandlePan(handlingState: handlingState, action: action)
        }
    }

    private func handleZoomPan(translation: CGPoint, state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            viewState.zoom.beginPan()
            viewState.zoom.updatePan(translation: translation)

        case .changed:
            viewState.zoom.updatePan(translation: translation)

        case .ended:
            viewState.zoom.updatePan(translation: translation)
            fallthrough

        case .cancelled, .failed:
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                viewState.zoom.endPan()
            }

        default:
            break
        }
    }

    private func unpackAndHandlePan(
        handlingState: _PanHandlingState,
        action: some _PanHandlingAction
    ) {
        action.onChange(
            action.startState,
            handlingState,
            viewState
        )
    }

    private func makePanHandlingAction(
        direction: Direction,
        location: CGPoint,
        unitPoint: UnitPoint
    ) -> any _PanHandlingAction {
        let newAction: any _PanHandlingAction = {
            if viewState.isPresentingControls {
                Self.SupplementPanHandlingAction
            } else if direction.isVertical {
                panActionForGestureAction(for: verticalPanAction(at: unitPoint.x))
            } else {
                panActionForGestureAction(
                    for: Defaults[.VideoPlayer.Gesture.horizontalPanAction]
                )
            }
        }()

        func unpackAndSetStartState<Handler: _PanHandlingAction>(
            action: Handler
        ) -> Handler {
            var action = action

            action.startState = _PanStartHandlingState(
                direction: direction,
                location: location,
                value: action.startValue(viewState)
            )

            return action
        }

        return unpackAndSetStartState(action: newAction)
    }

    private func panActionForGestureAction(for gestureAction: PanGestureAction) -> any _PanHandlingAction {
        let isLiveStream = viewState.mediaSession?.item.isLiveStream == true

        switch (gestureAction, isLiveStream) {
        case (.none, _), (.scrub, true), (.slowScrub, true):
            return Self.SupplementPanHandlingAction
        case (.brightness, _):
            return Self.BrightnessPanHandlingAction
        case (.scrub, false):
            return Self.ScrubPanHandlingAction()
        case (.slowScrub, false):
            return Self.ScrubPanHandlingAction(damping: 0.1)
        case (.volume, _):
            return Self.VolumePanHandlingAction
        }
    }

    private func handleSwipeAction(direction: Direction) {
        guard viewState.mediaSession?.canSeek == true else { return }

        let jumpProgressObserver = viewState.jumpProgressObserver
        viewState.showProgress()

        if direction == .left {
            let interval = Defaults[.VideoPlayer.jumpBackwardInterval]
            viewState.mediaSession?.seek(by: .zero - (interval.rawValue))
            jumpProgressObserver.jumpBackward()

            viewState.toastProxy.present(
                Text(
                    interval.rawValue * jumpProgressObserver.jumps,
                    format: .minuteSecondsNarrow
                ),
                systemName: "gobackward"
            )
        } else if direction == .right {
            let interval = Defaults[.VideoPlayer.jumpForwardInterval]
            viewState.mediaSession?.seek(by: interval.rawValue)
            jumpProgressObserver.jumpForward()

            viewState.toastProxy.present(
                Text(
                    interval.rawValue * jumpProgressObserver.jumps,
                    format: .minuteSecondsNarrow
                ),
                systemName: "goforward"
            )
        }
    }
}

// MARK: - Pan actions

extension VideoPlayer.UIContainerViewController {

    // MARK: - Brightness

    private static var BrightnessPanHandlingAction: PanHandlingAction<CGFloat> {
        PanHandlingAction<CGFloat>(
            startValue: { state in
                state.containerView?.view.window?.windowScene?.screen.brightness ?? 0.5
            }
        ) { startState, handlingState, viewState in
            // Terminal events settle ownership, not the adjustment value.
            guard handlingState.gestureState == .began || handlingState.gestureState == .changed else { return }

            let translation: CGFloat = {
                if startState.direction.isHorizontal {
                    handlingState.translation.x
                } else {
                    -handlingState.translation.y
                }
            }()

            let newBrightness = clamp(
                startState.value + CGFloat(translation / 300),
                min: 0,
                max: 1
            )

            viewState.toastProxy.present(
                Text(newBrightness, format: .percent.precision(.fractionLength(0))),
                systemName: "sun.max.fill"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                viewState.containerView?.view.window?.windowScene?.screen.brightness = newBrightness
            }
        }
    }

    // MARK: - Scrub

    private static func ScrubPanHandlingAction(
        damping: CGFloat = 1
    ) -> PanHandlingAction<Duration> {
        PanHandlingAction<Duration>(
            startValue: { viewState in
                viewState.beginScrub()

                return viewState.scrubbedSeconds
            }
        ) { startState, handlingState, viewState in
            if handlingState.gestureState == .cancelled || handlingState.gestureState == .failed {
                viewState.cancelScrub()
                return
            }

            if handlingState.gestureState == .ended {
                viewState.commitScrub()
                return
            }

            guard viewState.mediaSession?.canSeek == true, let runtime = viewState.mediaSession?.item.runtime else { return }

            let translation: CGFloat = {
                if startState.direction.isHorizontal {
                    handlingState.translation.x
                } else {
                    -handlingState.translation.y
                }
            }()

            let totalSize: CGFloat = {
                if startState.direction.isHorizontal {
                    handlingState.location.x / handlingState.unitPoint.x
                } else {
                    handlingState.location.y / handlingState.unitPoint.y
                }
            }()

            viewState.beginScrub()

            guard totalSize.isFinite, totalSize > 0 else { return }

            let newSeconds = clamp(
                startState.value.seconds + (translation / totalSize) * runtime.seconds * damping,
                min: 0,
                max: runtime.seconds
            )

            let newSecondsDuration = Duration.seconds(newSeconds)

            viewState.scrubbedSeconds = newSecondsDuration
        }
    }

    // MARK: - Supplement

    private static var SupplementPanHandlingAction: PanHandlingAction<CGFloat> {
        PanHandlingAction<CGFloat>(
            startValue: 0
        ) { _, handlingState, viewState in
            viewState.containerView?.handleSupplementPanAction(
                translation: handlingState.translation,
                velocity: handlingState.velocity.y,
                state: handlingState.gestureState
            )
        }
    }

    // MARK: - Volume

    private static var VolumePanHandlingAction: PanHandlingAction<Float> {
        // Retain one system volume view for the gesture instead of rebuilding it on every move.
        let volumeView = MPVolumeView()

        return PanHandlingAction<Float>(
            startValue: AVAudioSession.sharedInstance().outputVolume
        ) { startState, handlingState, _ in
            guard handlingState.gestureState == .began || handlingState.gestureState == .changed,
                  let slider = volumeView
                    .subviews
                    .first(where: { $0 is UISlider }) as? UISlider else { return }

            let translation: CGFloat = {
                if startState.direction.isHorizontal {
                    handlingState.translation.x
                } else {
                    -handlingState.translation.y
                }
            }()

            let newVolume = clamp(
                startState.value + Float(translation / 300),
                min: 0,
                max: 1
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                slider.value = newVolume
            }
        }
    }
}
