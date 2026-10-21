import Foundation
import XCTest

/// S2: `Config/PrivacyInfo.xcprivacy` declares what leaves the device when an account is used (watch progress /
/// favorites with titles, device key, purchases – linked to the account) and the required-reason APIs.
final class PrivacyManifestTests: XCTestCase {
    func testManifestDeclaresSyncedDataAndRequiredReasonAPIs() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/PrivacyInfo.xcprivacy")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        var linked: [String: Bool] = [:]
        for entry in collected {
            linked[try XCTUnwrap(entry["NSPrivacyCollectedDataType"] as? String)] = entry["NSPrivacyCollectedDataTypeLinked"] as? Bool
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        }
        for type in ["DeviceID", "PurchaseHistory", "EmailAddress", "ProductInteraction", "OtherUserContent"] {
            XCTAssertEqual(linked["NSPrivacyCollectedDataType\(type)"], true, type)
        }
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for api in apis { reasons[api["NSPrivacyAccessedAPIType"] as? String ?? ""] = api["NSPrivacyAccessedAPITypeReasons"] as? [String] }
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
    }
}
