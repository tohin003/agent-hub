import SwiftUI

@main
struct AgentHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = HubStore()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "screenGestureTest") {
                ScreenGestureHarness()
            } else if UserDefaults.standard.bool(forKey: "screenLayoutTest") {
                ScreenLayoutHarness()
            } else {
                root
            }
            #else
            root
            #endif
        }
    }

    private var root: some View {
        RootView()
            .environment(store)
            .onAppear { appDelegate.store = store }
    }
}
