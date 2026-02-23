import Network
import Observation

// MARK: - BonjourBrowser

/// Discovers World Tree servers on the local network via NWBrowser / Bonjour.
///
/// Publishes `servers` as a sorted array of resolved `DiscoveredServer` values.
/// Call `start()` when the picker appears and `stop()` when it disappears.
@Observable
@MainActor
final class BonjourBrowser {

    // MARK: - Discovered Server

    struct DiscoveredServer: Identifiable, Equatable {
        let id: String      // raw service name (stable key)
        let name: String    // display name (hostname component)
        let host: String    // hostname.local — resolved by mDNS
        let port: Int
    }

    // MARK: - Public State

    private(set) var servers: [DiscoveredServer] = []
    private(set) var isSearching = false

    // MARK: - Private

    private var browser: NWBrowser?

    // MARK: - Lifecycle

    func start() {
        guard browser == nil else { return }
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: Constants.Network.bonjourServiceType,
                domain: Constants.Network.bonjourDomain
            ),
            using: params
        )
        browser = b

        b.browseResultsChangedHandler = { [weak self] (results: Set<NWBrowser.Result>, _: Set<NWBrowser.Result.Change>) in
            Task { @MainActor [weak self] in
                self?.applyResults(results)
            }
        }

        b.stateUpdateHandler = { [weak self] (state: NWBrowser.State) in
            Task { @MainActor [weak self] in
                switch state {
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        b.start(queue: DispatchQueue.main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        servers = []
        isSearching = false
    }

    // MARK: - Result Processing

    private func applyResults(_ results: Set<NWBrowser.Result>) {
        servers = results.compactMap { result in
            guard case .service(let serviceName, _, _, _) = result.endpoint else { return nil }
            return parseService(name: serviceName)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Parse service name into a `DiscoveredServer`.
    ///
    /// The Mac World Tree server registers with name `"Hostname:Port"`.
    /// Fall back to `Constants.Network.defaultPort` when the port is absent.
    private func parseService(name serviceName: String) -> DiscoveredServer {
        let parts = serviceName.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let displayName = parts.first.map(String.init) ?? serviceName
        let port = parts.count > 1 ? Int(String(parts[1])) ?? Constants.Network.defaultPort
                                   : Constants.Network.defaultPort

        // mDNS resolves hostname.local on the local network automatically.
        let host = "\(displayName).local"

        return DiscoveredServer(id: serviceName, name: displayName, host: host, port: port)
    }
}
