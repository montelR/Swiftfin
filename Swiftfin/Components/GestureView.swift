//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import Logging
import SwiftUI

struct GestureView: View {

    var allowsDownwardPan: ((UIPanGestureRecognizer) -> Bool)?

    @ContentBuilder
    var body: some View {
        GestureViewRepresentable(allowsDownwardPan: allowsDownwardPan)
            .accessibilityHidden(true)
    }
}

private struct GestureViewRepresentable: PlatformViewRepresentable {

    let allowsDownwardPan: ((UIPanGestureRecognizer) -> Bool)?

    func makeUIView(context: Context) -> UIView {
        let view = PanSurfaceView(frame: .zero)
        view.onDetach = { [weak coordinator = context.coordinator] in
            coordinator?.cancelActivePan()
        }

        view.addGestureRecognizer(context.coordinator.longPressGesture)
        view.addGestureRecognizer(context.coordinator.panGesture)
        view.addGestureRecognizer(context.coordinator.pinchGesture)
        view.addGestureRecognizer(context.coordinator.tapGesture)
        view.addGestureRecognizer(context.coordinator.doubleTouchGesture)
        context.coordinator.doubleTouchGesture.require(toFail: context.coordinator.pinchGesture)

        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.longPressAction = context.environment.longPressAction
        context.coordinator.panAction = context.environment.panAction
        context.coordinator.pinchAction = context.environment.pinchAction
        context.coordinator.tapAction = context.environment.tapGestureAction

        context.coordinator.panGesture.direction = context.environment.panGestureDirection
        context.coordinator.panGesture.allowsDownwardPan = allowsDownwardPan
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cancelActivePan()
        coordinator.panAction = nil
    }

    private final class PanSurfaceView: UIView {

        var onDetach: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                onDetach?()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {

        lazy var doubleTouchGesture: UITapGestureRecognizer! = {
            let recognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(handleTap)
            )
            recognizer.numberOfTouchesRequired = 2
            return recognizer
        }()

        lazy var longPressGesture: UILongPressGestureRecognizer! = {
            let recognizer = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress)
            )
            recognizer.minimumPressDuration = 0.5
            return recognizer
        }()

        lazy var panGesture: DirectionalPanGestureRecognizer! = {
            let recognizer = DirectionalPanGestureRecognizer(
                direction: .allButDown,
                target: self,
                action: #selector(handlePan)
            )
            recognizer.maximumNumberOfTouches = 1
            return recognizer
        }()

        lazy var pinchGesture: UIPinchGestureRecognizer! = {
            .init(
                target: self,
                action: #selector(handlePinch)
            )
        }()

        lazy var tapGesture: UITapGestureRecognizer! = {
            .init(
                target: self,
                action: #selector(handleTap)
            )
        }()

        var longPressAction: LongPressAction? {
            didSet { longPressGesture.isEnabled = longPressAction != nil }
        }

        var panAction: PanAction? {
            didSet {
                if panAction?.tracksIdentity != true {
                    cancelActivePan()
                }
                panGesture.isEnabled = panAction != nil
            }
        }

        var pinchAction: PinchAction? {
            didSet { pinchGesture.isEnabled = pinchAction != nil }
        }

        var tapAction: TapAction? {
            didSet {
                doubleTouchGesture.isEnabled = tapAction != nil
                tapGesture.isEnabled = tapAction != nil
            }
        }

        private let panRecognizerID = UUID()
        private var activePan: (identity: PanGestureIdentity, action: PanAction, location: CGPoint, unitPoint: UnitPoint)?

        func cancelActivePan() {
            guard let pan = activePan else { return }

            activePan = nil
            pan.action(
                translation: .zero,
                velocity: .zero,
                location: pan.location,
                unitPoint: pan.unitPoint,
                state: .cancelled,
                identity: pan.identity
            )
        }

        @objc
        func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }

            let location = gesture.location(in: view)
            let unitPoint = UnitPoint(
                x: location.x / view.bounds.width,
                y: location.y / view.bounds.height
            )

            longPressAction?(
                location: location,
                unitPoint: unitPoint,
                state: gesture.state
            )
        }

        @objc
        func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else {
                cancelActivePan()
                return
            }

            // Non-playback gestures retain their existing callback semantics.
            if let panAction, !panAction.tracksIdentity {
                let location = gesture.location(in: view)
                panAction(
                    translation: gesture.translation(in: view),
                    velocity: gesture.velocity(in: view),
                    location: location,
                    unitPoint: UnitPoint(
                        x: location.x / view.bounds.width,
                        y: location.y / view.bounds.height
                    ),
                    state: gesture.state
                )
                return
            }

            guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
                cancelActivePan()
                return
            }

            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)
            let location = gesture.location(in: view)
            let unitPoint = UnitPoint(
                x: location.x / view.bounds.width,
                y: location.y / view.bounds.height
            )

            let state = gesture.state
            if state == .began {
                guard activePan == nil, let panAction else { return }

                activePan = (
                    .init(recognizer: panRecognizerID, sequence: UUID()),
                    panAction,
                    location,
                    unitPoint
                )
            }

            guard let pan = activePan else { return }

            switch state {
            case .began, .changed:
                activePan?.location = location
                activePan?.unitPoint = unitPoint

            case .ended, .cancelled, .failed:
                activePan = nil

            default:
                return
            }

            pan.action(
                translation: translation,
                velocity: velocity,
                location: location,
                unitPoint: unitPoint,
                state: state,
                identity: pan.identity
            )
        }

        @objc
        func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed {
                guard gesture.numberOfTouches == 2 else { return }
            }

            pinchAction?(
                scale: gesture.scale,
                location: gesture.location(in: gesture.view),
                state: gesture.state
            )
        }

        @objc
        func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }

            let location = gesture.location(in: gesture.view)
            let unitPoint = UnitPoint(
                x: location.x / view.bounds.width,
                y: location.y / view.bounds.height
            )

            tapAction?(
                location: location,
                unitPoint: unitPoint,
                count: gesture.numberOfTouchesRequired
            )
        }
    }
}
