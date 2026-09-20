import XCTest
import GRDB
@testable import HealthManager

final class HealthBridgeIntegrationTests: XCTestCase {
    func testRealMigrationTriggersCaptureUpdatesAndDeletesWithoutPhotos() throws {
        let database=DatabaseManager.makeInMemoryForTesting()
        try database.write { db in
            try BridgeSource.setEnabled(true,db:db)
            try db.execute(sql:"INSERT INTO meal_records(meal_type,eaten_at,notes,photo_path,created_at) VALUES('dinner',100,'before','private.jpg',100)")
            try BridgeSource.prepare(db,historyStart:Date(timeIntervalSince1970:0),timeZone:"Asia/Shanghai")
        }
        let initial=try database.read { try Row.fetchOne($0,sql:"SELECT * FROM bridge_outbox ORDER BY sequence DESC LIMIT 1")! }
        let data:Data=initial["payload"]
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("private.jpg"))
        try database.write { db in
            try db.execute(sql:"UPDATE meal_records SET notes='after'")
            try BridgeSource.prepare(db,historyStart:Date(timeIntervalSince1970:0))
        }
        let changed=try database.read { try Data.fetchOne($0,sql:"SELECT payload FROM bridge_outbox ORDER BY sequence DESC LIMIT 1")! }
        XCTAssertTrue(String(decoding:changed,as:UTF8.self).contains("after"))
        try database.write { db in
            try db.execute(sql:"DELETE FROM meal_records")
            try BridgeSource.prepare(db,historyStart:Date(timeIntervalSince1970:0))
        }
        let deleted=try database.read { try Data.fetchOne($0,sql:"SELECT payload FROM bridge_outbox ORDER BY sequence DESC LIMIT 1")! }
        let record=try JSONDecoder().decode(BridgeRecord.self,from:deleted)
        XCTAssertNil(record.json)
    }
}
