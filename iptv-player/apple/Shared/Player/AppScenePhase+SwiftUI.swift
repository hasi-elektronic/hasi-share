import IPTVKit
import SwiftUI

extension AppScenePhase {
    /// SwiftUI scene phase → `AppEnvironment.scenePhaseChanged(_:)` (B4: only `.background` releases the player).
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        default: self = .inactive
        }
    }
}
