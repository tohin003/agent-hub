import Foundation
import Security

/// Where the Mac is and how to prove it's you: the tailnet names and the pairing token. The build carries your
/// Mac's values (Config/Local.xcconfig); a pairing link from the Mac's menu bar can replace them later.
struct HubSettings: Equatable {
    var hosts: [String]
    var port: Int
    var token: String
    var macName: String

    var isConfigured: Bool { !hosts.isEmpty && token.count >= 32 }

    static func load() -> HubSettings {
        let bundle = Bundle.main
        let defaults = UserDefaults.standard
        let builtHosts = (bundle.object(forInfoDictionaryKey: "AgentHubHosts") as? String ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains("$(") }
        let builtPort = Int(bundle.object(forInfoDictionaryKey: "AgentHubPort") as? String ?? "") ?? WireProtocol.defaultPort
        let builtToken = (bundle.object(forInfoDictionaryKey: "AgentHubToken") as? String ?? "").trimmingCharacters(in: .whitespaces)
        let builtName = bundle.object(forInfoDictionaryKey: "AgentHubMacName") as? String ?? "Mac"

        let savedHosts = defaults.stringArray(forKey: "hub.hosts")
        let savedPort = defaults.integer(forKey: "hub.port")
        let savedName = defaults.string(forKey: "hub.macName")
        let savedToken = Keychain.read("hub.token")
        var hosts = savedHosts ?? builtHosts
        #if targetEnvironment(simulator)
        // The simulator shares the Mac's network, and a Mac can't reach its own tailnet address: use loopback.
        hosts.insert("127.0.0.1", at: 0)
        #endif
        return HubSettings(hosts: hosts,
                           port: savedPort > 0 ? savedPort : builtPort,
                           token: savedToken ?? (builtToken.contains("$(") ? "" : builtToken),
                           macName: savedName ?? (builtName.contains("$(") ? "Mac" : builtName))
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(hosts, forKey: "hub.hosts")
        defaults.set(port, forKey: "hub.port")
        defaults.set(macName, forKey: "hub.macName")
        Keychain.write("hub.token", token)
    }

    /// Reads agenthub://pair?hosts=a,b&port=7860&token=…&name=…
    static func fromPairingLink(_ url: URL) -> HubSettings? {
        guard url.scheme == "agenthub", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let hosts = (value("hosts") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty, let token = value("token"), token.count >= 32 else { return nil }
        return HubSettings(hosts: hosts, port: Int(value("port") ?? "") ?? WireProtocol.defaultPort, token: token,
                           macName: value("name") ?? "Mac")
    }
}

/// The token lives in the Keychain, never in UserDefaults.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "AgentHub"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// When this build's signing ends (free provisioning lasts 7 days), read from the app's own profile.
enum SigningInfo {
    static let expiration: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        // The profile is a signed plist; the plist itself sits in the middle as plain XML.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else { return nil }
        let plistData = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }()
}
