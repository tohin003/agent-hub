import UIKit

/// Which way the app may turn. Agent Hub stands upright everywhere; the Screen tab can lay it on its side while it's
/// shown, so the Mac's picture fills the height, and then either landscape direction follows the phone. The app
/// delegate hands iOS the mask. Leaving the Screen tab, or the app, stands it upright again.
final class OrientationLock {
    static let shared = OrientationLock()

    /// What iOS may show now.
    private(set) var mask: UIInterfaceOrientationMask = .portrait

    /// Whether the app turns when asked: on an iPhone. An iPad turns with the person's hand (its windows ignore the
    /// request), so it keeps every orientation.
    var canRotate: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// What the app delegate tells iOS.
    var supported: UIInterfaceOrientationMask { canRotate ? mask : .all }

    /// Landscape, either way round.
    func allowLandscape() { request(.landscape) }

    /// Upright again, as the rest of the app is.
    func standUpright() { request(.portrait) }

    /// Allows `mask` and asks every window to turn to it now. Asking again is harmless, so a request that didn't take
    /// can simply be repeated.
    private func request(_ new: UIInterfaceOrientationMask) {
        guard canRotate else { return }
        mask = new
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: new))
        }
    }
}
