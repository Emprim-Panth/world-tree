import XCTest
@testable import WorldTree

final class PluginMCPTransportTests: XCTestCase {
    func testInitializedNotificationUsesAcceptedEmptyResponse() {
        let plan = PluginMCPTransport.responsePlan(
            forMethod: "notifications/initialized",
            hasRequestID: false
        )

        XCTAssertEqual(plan, PluginMCPHTTPResponsePlan(status: 202, body: nil, contentType: nil))
    }

    func testRequestsWithoutIDAreTreatedAsNotifications() {
        let plan = PluginMCPTransport.responsePlan(forMethod: "tools/list", hasRequestID: false)

        XCTAssertEqual(plan, PluginMCPHTTPResponsePlan(status: 202, body: nil, contentType: nil))
    }

    func testNormalRequestKeepsJSONRPCResponseFlow() {
        XCTAssertNil(PluginMCPTransport.responsePlan(forMethod: "tools/list", hasRequestID: true))
    }
}
