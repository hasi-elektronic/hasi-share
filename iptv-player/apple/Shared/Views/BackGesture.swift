#if os(iOS)
import SwiftUI
import UIKit

// iPhone/iPad "swipe from the left edge goes back" (SCREENS §2). The app hides the navigation bar on its
// root and detail screens, and a hidden bar disables UINavigationController's interactive pop gesture
// (its default delegate refuses to begin). Pages presented full screen (category sheet) get the same
// edge swipe. The player keeps its own gestures and is not touched.

/// Re-enables the edge-swipe pop on the enclosing UINavigationController while its bar is hidden. Put it in
/// the background of a NavigationStack's root view; it stays alive (and the delegate with it) as long as the
/// stack exists.
struct InteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.attach() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attach()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        func attach() {
            guard let pop = navigationController?.interactivePopGestureRecognizer else { return }
            pop.isEnabled = true
            if pop.delegate !== self { pop.delegate = self }
        }

        /// Only with something to go back to and no push/pop animating: replacing the system delegate drops
        /// UIKit's own "no pop during a transition" guard, and a pop started mid-push freezes the stack.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = navigationController else { return false }
            return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
        }
    }
}

/// Left-edge swipe that dismisses a full-screen page (same feel as back): starts within 24 pt of the left
/// edge, mostly horizontal; the page follows the finger and closes past 80 pt, otherwise springs back.
/// Edge-only start, so lists, shelves and swipe actions keep their own gestures.
struct EdgeSwipeDismiss: ViewModifier {
    static let edgeWidth: CGFloat = 24
    static let threshold: CGFloat = 80
    let dismiss: () -> Void
    /// Resets by itself when the gesture ends or the system cancels it (springs back).
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.25))) private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .updating($offset) { value, state, _ in
                        guard value.startLocation.x <= Self.edgeWidth else { return }
                        let dx = value.translation.width, dy = value.translation.height
                        guard dx > 0, abs(dy) < dx else { return }
                        state = dx
                    }
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        if value.startLocation.x <= Self.edgeWidth, dx > Self.threshold, abs(dy) < dx * 0.6 { dismiss() }
                    }
            )
    }
}

extension View {
    /// See `EdgeSwipeDismiss`.
    func edgeSwipeToDismiss(_ dismiss: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeDismiss(dismiss: dismiss))
    }
}
#endif
