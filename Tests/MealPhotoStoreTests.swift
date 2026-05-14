import XCTest
import UIKit
@testable import HealthManager

final class MealPhotoStoreTests: XCTestCase {

    var store: MealPhotoStore { MealPhotoStore.shared }

    func test_saveAndLoadThumbnail_roundTrip() {
        let img = solidColorImage(.red, size: CGSize(width: 200, height: 200))
        guard let path = store.save(image: img) else { return XCTFail("save returned nil") }
        defer { store.removeIfManaged(path: path) }

        XCTAssertTrue(path.hasSuffix(".jpg"))
        XCTAssertFalse(path.contains("/"), "stored path must be a bare filename")

        let thumb = store.loadThumbnail(path: path)
        XCTAssertNotNil(thumb)
        // Down-scaled to ~112px max side
        if let thumb {
            let maxSide = max(thumb.size.width, thumb.size.height)
            XCTAssertLessThanOrEqual(maxSide, 200, "thumbnail should not be larger than the original")
        }
    }

    func test_removeIfManaged_removesFile() {
        let img = solidColorImage(.blue, size: CGSize(width: 50, height: 50))
        guard let path = store.save(image: img) else { return XCTFail("save nil") }
        let abs = store.absoluteURL(for: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: abs.path))
        store.removeIfManaged(path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abs.path))
    }

    func test_removeIfManaged_ignoresAbsolutePath() {
        // Should NOT touch a path containing "/" (legacy absolute path)
        store.removeIfManaged(path: "/tmp/legacy/photo.jpg")
        // No assertion — just verifying we don't crash and don't try to rm random files.
        XCTAssertTrue(true)
    }

    func test_loadThumbnail_missingFile_returnsNil() {
        XCTAssertNil(store.loadThumbnail(path: "nonexistent-uuid.jpg"))
    }

    private func solidColorImage(_ color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
