import XCTest
@testable import HealthManager

/// 参考表合同（验收 D1~D3、D2 备份部分在 BackupV3Tests）：
/// 一次性种子、移除=状态、幂等导入、显示名编辑、成员状态查询。
final class PersonalReferenceStoreTests: XCTestCase {

    private func makeStore(now: @escaping @Sendable () -> Int64 = { 1_000 }) -> PersonalCatalogStore {
        PersonalCatalogStore(databaseManager: DatabaseManager.makeInMemoryForTesting(), now: now)
    }

    private var bundled: FoodCatalogStore {
        // 单测 host 是 App 本体。
        (try? FoodCatalogStore(bundle: .main))!
    }

    private func seedFlags() -> (reader: @Sendable (String) -> Bool?, writer: @Sendable (String, Bool) -> Void, box: SeedBox) {
        let box = SeedBox()
        return (
            { key in box.storage[key] as Bool? },
            { key, value in box.storage[key] = value },
            box
        )
    }

    final class SeedBox: @unchecked Sendable {
        var storage: [String: Bool] = [:]
    }

    // MARK: 种子（D3 的前提）

    func test_seed_initializesAllCatalogEntriesOnce() async throws {
        let store = makeStore()
        let flags = seedFlags()
        try await store.seedIfNeeded(bundled: bundled, seedFlagReader: flags.reader, seedFlagWriter: flags.writer)

        let members = try await store.activeMembers()
        XCTAssertEqual(members.count, bundled.catalog.entries.count)
        XCTAssertTrue(members.contains { $0.entry.id == "mext-01088" })

        // 二次启动：不再重复播种（幂等）。
        try await store.removeMember(id: members[0].member.id!)
        try await store.seedIfNeeded(bundled: bundled, seedFlagReader: flags.reader, seedFlagWriter: flags.writer)
        let after = try await store.activeMembers()
        XCTAssertEqual(after.count, members.count - 1, "已移除成员不被种子复活")
    }

    func test_seed_notReplayedWhenFlagPreSet_simulatingRestore() async throws {
        // 模拟恢复：标记随备份设置恢复为 true 后，即使表为空也不重播（D3）。
        let store = makeStore()
        let flags = seedFlags()
        flags.writer(PersonalCatalogStore.seedFlagKey, true)
        try await store.seedIfNeeded(bundled: bundled, seedFlagReader: flags.reader, seedFlagWriter: flags.writer)
        let members = try await store.activeMembers()
        XCTAssertTrue(members.isEmpty)
    }

    // MARK: 移除/恢复（D1/D2 语义层）

    func test_removeAndRestore_isStateChangeWithoutDuplicates() async throws {
        let store = makeStore()
        let flags = seedFlags()
        try await store.seedIfNeeded(bundled: bundled, seedFlagReader: flags.reader, seedFlagWriter: flags.writer)
        let allMembers = try await store.activeMembers()
        let egg = try XCTUnwrap(allMembers.first { $0.entry.id == "mext-12005" })

        // 移除（重复移除幂等）
        try await store.removeMember(id: egg.member.id!)
        try await store.removeMember(id: egg.member.id!)
        let activeAfterRemove = try await store.activeMembers()
        XCTAssertFalse(activeAfterRemove.contains { $0.entry.id == "mext-12005" })
        let removed = try await store.removedMembers()
        XCTAssertEqual(removed.count, 1)

        // 重新添加（恢复）不产生副本
        try await store.restoreMember(id: egg.member.id!)
        let activeAfterRestore = try await store.activeMembers()
        XCTAssertEqual(activeAfterRestore.filter { $0.entry.id == "mext-12005" }.count, 1)
        let removedAfterRestore = try await store.removedMembers()
        XCTAssertEqual(removedAfterRestore.count, 0)
    }

    // MARK: 导入幂等（S5 持久层）

    func test_importEntries_isIdempotentByIdentity_notByChineseName() async throws {
        let store = makeStore()
        let flags = seedFlags()
        try await store.seedIfNeeded(bundled: bundled, seedFlagReader: flags.reader, seedFlagWriter: flags.writer)

        // 同一官方身份、不同显示名：不产生第二个成员。
        var dark = bundled.entry(id: "mext-12005")!
        dark.nameZh = "水煮蛋（英式）"
        let ids1 = try await store.importEntries([
            .init(entry: dark, displayName: "水煮蛋（英式）", versionLabel: bundled.catalog.source.edition)
        ])
        let ids2 = try await store.importEntries([
            .init(entry: dark, displayName: "水煮蛋（英式）", versionLabel: bundled.catalog.source.edition)
        ])
        XCTAssertEqual(ids1.count, 1)
        XCTAssertEqual(ids2.count, 1)
        let members = try await store.activeMembers()
        XCTAssertEqual(members.filter { $0.entry.id == "mext-12005" }.count, 1)
        XCTAssertEqual(members.first { $0.entry.id == "mext-12005" }?.member.displayName, "水煮蛋（英式）")
    }

    func test_importNewVersion_appendsVersionRow_withoutChangingMembershipPointer() async throws {
        let store = makeStore()
        let flags = seedFlags()
        try await store.seedIfNeeded(bundled: bundled, seedFlagReader: flags.reader, seedFlagWriter: flags.writer)
        let allMembers = try await store.activeMembers()
        let rice = try XCTUnwrap(allMembers.first { $0.entry.id == "mext-01088" })
        let originalVersionId = rice.version.id

        // 同身份、不同版本标签 → 追加新版本行；成员版本指针保持不变（显式采用才升级）。
        var rice2024 = rice.entry
        rice2024.nutrients.kcal = FoodCatalogNutrient(value: 150, flag: .measured)
        _ = try await store.importEntries([
            .init(entry: rice2024, displayName: rice.member.displayName, versionLabel: "FDC-style-2024")
        ])

        let after = try await store.activeMembers().first { $0.entry.id == "mext-01088" }!
        XCTAssertEqual(after.version.id, originalVersionId, "成员指向旧版本，不自动升级")
        XCTAssertEqual(try XCTUnwrap(after.version.nutrients).kcal.value, 156, "显示值仍是选用版本的值")
    }

    func test_membershipState_distinguishesNeverAddedActiveRemoved() async throws {
        let store = makeStore()
        let flags = seedFlags()
        try await store.seedIfNeeded(bundled: bundled, seedFlagReader: flags.reader, seedFlagWriter: flags.writer)

        let rice = try await store.membershipState(provider: "MEXT", providerFoodId: "01088")
        XCTAssertEqual(rice, true)
        let egg = try await store.activeMembers().first { $0.entry.id == "mext-12005" }!
        try await store.removeMember(id: egg.member.id!)
        let eggState = try await store.membershipState(provider: "MEXT", providerFoodId: "12005")
        XCTAssertEqual(eggState, false)
        let unknown = try await store.membershipState(provider: "USDA", providerFoodId: "999999")
        XCTAssertNil(unknown)
    }

    // MARK: 显示名/别名（§3.2-7）

    func test_displayNameEdit_doesNotChangeOriginalOrNutrients() async throws {
        let store = makeStore()
        let flags = seedFlags()
        try await store.seedIfNeeded(bundled: bundled, seedFlagReader: flags.reader, seedFlagWriter: flags.writer)
        let allMembers = try await store.activeMembers()
        let egg = try XCTUnwrap(allMembers.first { $0.entry.id == "mext-12005" })

        try await store.setDisplayName(memberId: egg.member.id!, name: "常买的蛋")
        try await store.setCustomAliases(memberId: egg.member.id!, aliases: ["白煮蛋", " 蛋蛋 "])

        let after = try await store.activeMembers().first { $0.entry.id == "mext-12005" }!
        XCTAssertEqual(after.member.displayName, "常买的蛋")
        XCTAssertEqual(after.entry.nameOriginal, "鶏卵 全卵 ゆで")
        XCTAssertEqual(try XCTUnwrap(after.version.nutrients).kcal.value, 134, "营养值不因显示名改变")
        XCTAssertEqual(after.aliases, ["白煮蛋", "蛋蛋"], "别名去空白")
    }

    // MARK: 快照捕获（V1 前提）

    func test_captureSnapshot_usesStoredVersion_andReturnsNilForUnknownIdentity() async throws {
        let store = makeStore()
        let flags = seedFlags()
        try await store.seedIfNeeded(bundled: bundled, seedFlagReader: flags.reader, seedFlagWriter: flags.writer)

        let snapshot = try await store.captureSnapshot(entryId: "mext-01088", capturedAt: 42)
        XCTAssertEqual(snapshot?.provider, "MEXT")
        XCTAssertEqual(snapshot?.providerFoodId, "01088")
        XCTAssertEqual(snapshot?.per100.kcal.value, 156)
        XCTAssertEqual(snapshot?.capturedAt, 42)
        let unknownSnapshot = try await store.captureSnapshot(entryId: "usda-424242", capturedAt: 1)
        XCTAssertNil(unknownSnapshot)
    }
}
