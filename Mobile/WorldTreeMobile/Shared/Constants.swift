import Foundation

enum Constants {
    enum Network {
        static let defaultPort = 5865
        static let bonjourServiceType = "_worldtree._tcp"
        static let bonjourDomain = "local."
        static let reconnectMaxAttempts = 10
        static let backgroundDisconnectDelay: TimeInterval = 30
    }

    enum UserDefaultsKeys {
        static let lastServerId = "lastServerId"
        static let lastTreeId = "lastTreeId"
        static let lastBranchId = "lastBranchId"
        static let autoConnect = "autoConnect"
        static let messageFontSize = "messageFontSize"
    }

    enum Defaults {
        static let autoConnect = true
        static let messageFontSize = 15.0
    }
}
