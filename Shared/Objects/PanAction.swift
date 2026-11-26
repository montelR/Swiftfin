//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

extension EnvironmentValues {

    @Entry
    var panAction: PanAction? = nil
}

/// A recognizer can produce many pans. Match both the surface and the gesture lifetime.
struct PanGestureIdentity: Equatable {

    let recognizer: UUID
    let sequence: UUID
}

struct PanAction {

    private let action: (
        _ translation: CGPoint,
        _ velocity: CGPoint,
        _ location: CGPoint,
        _ unitPoint: UnitPoint,
        _ state: UIGestureRecognizer.State,
        _ identity: PanGestureIdentity?
    ) -> Void

    let tracksIdentity: Bool

    init(action: @escaping (CGPoint, CGPoint, CGPoint, UnitPoint, UIGestureRecognizer.State) -> Void) {
        tracksIdentity = false
        self.action = { translation, velocity, location, unitPoint, state, _ in
            action(translation, velocity, location, unitPoint, state)
        }
    }

    init(identifiedAction: @escaping (CGPoint, CGPoint, CGPoint, UnitPoint, UIGestureRecognizer.State, PanGestureIdentity) -> Void) {
        tracksIdentity = true
        action = { translation, velocity, location, unitPoint, state, identity in
            guard let identity else { return }

            identifiedAction(translation, velocity, location, unitPoint, state, identity)
        }
    }

    func callAsFunction(
        translation: CGPoint,
        velocity: CGPoint,
        location: CGPoint,
        unitPoint: UnitPoint,
        state: UIGestureRecognizer.State,
        identity: PanGestureIdentity? = nil
    ) {
        action(
            translation,
            velocity,
            location,
            unitPoint,
            state,
            identity
        )
    }
}
