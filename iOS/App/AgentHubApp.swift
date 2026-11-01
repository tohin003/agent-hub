import SwiftUI

@main
struct AgentHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = HubStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onAppear { appDelegate.store = store }
        }
    }
}
