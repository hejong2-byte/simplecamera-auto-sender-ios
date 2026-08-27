import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class USBReceiverPolicyTests: XCTestCase {
    func testCellularIsDisabledByDefaultAndPersistsExplicitOptIn() {
        let suite = "USBReceiverPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = USBReceiverPreferences(defaults: defaults)
        XCTAssertFalse(preferences.allowsCellular)

        preferences.allowsCellular = true

        XCTAssertTrue(USBReceiverPreferences(defaults: defaults).allowsCellular)
    }

    func testNetworkConfigurationsEnforceWiFiOnlyUnlessOptedIn() {
        let wifiOnly = USBReceiverNetworkPolicy.configuration(allowsCellular: false)
        let cellular = USBReceiverNetworkPolicy.configuration(allowsCellular: true)

        XCTAssertFalse(wifiOnly.allowsCellularAccess)
        XCTAssertFalse(wifiOnly.allowsExpensiveNetworkAccess)
        XCTAssertTrue(cellular.allowsCellularAccess)
        XCTAssertTrue(cellular.allowsExpensiveNetworkAccess)
    }

    func testFAT32RejectsFilesLargerThanFourGiBButExFATAcceptsThem() {
        let fourGiB = Int64(4) * 1_024 * 1_024 * 1_024

        XCTAssertThrowsError(
            try USBVolumePolicy.validate(
                fileSize: fourGiB,
                formatDescription: "MS-DOS (FAT32)"
            )
        )
        XCTAssertNoThrow(
            try USBVolumePolicy.validate(
                fileSize: fourGiB,
                formatDescription: "ExFAT"
            )
        )
    }
}
