import XCTest
@testable import HealthManager

final class SourceAttributionTests: XCTestCase {

    func test_garminFromBundleId() {
        XCTAssertEqual(
            SourceAttribution.classify(bundleId: "com.garmin.connect.mobile", sourceName: nil),
            .garmin
        )
    }

    func test_garminFromSourceName() {
        XCTAssertEqual(
            SourceAttribution.classify(bundleId: nil, sourceName: "Garmin Connect"),
            .garmin
        )
    }

    func test_xiaomiMijia_chineseName() {
        XCTAssertEqual(
            SourceAttribution.classify(bundleId: nil, sourceName: "米家"),
            .xiaomiMijia
        )
    }

    func test_xiaomiSports_zepp() {
        XCTAssertEqual(
            SourceAttribution.classify(bundleId: nil, sourceName: "Zepp Life"),
            .xiaomiSports
        )
    }

    func test_appleHealth_dotApplePrefix() {
        XCTAssertEqual(
            SourceAttribution.classify(bundleId: "com.apple.Health", sourceName: nil),
            .apple
        )
    }

    func test_appleWatch_byName() {
        XCTAssertEqual(
            SourceAttribution.classify(bundleId: nil, sourceName: "Apple Watch"),
            .apple
        )
    }

    func test_manual_byOwnBundle() {
        XCTAssertEqual(
            SourceAttribution.classify(bundleId: "com.norte.HealthManager", sourceName: nil),
            .manual
        )
    }

    func test_unknown_default() {
        XCTAssertEqual(
            SourceAttribution.classify(bundleId: "io.totally.random", sourceName: "RandomApp"),
            .unknown
        )
    }

    func test_priorityOrder_garminHighest() {
        XCTAssertGreaterThan(
            SourceAttribution.Origin.garmin.cumulativePriority,
            SourceAttribution.Origin.apple.cumulativePriority
        )
        XCTAssertGreaterThan(
            SourceAttribution.Origin.apple.cumulativePriority,
            SourceAttribution.Origin.xiaomiSports.cumulativePriority
        )
        XCTAssertEqual(
            SourceAttribution.Origin.unknown.cumulativePriority,
            0
        )
    }
}
