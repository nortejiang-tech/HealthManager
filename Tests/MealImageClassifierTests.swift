import XCTest
@testable import HealthManager

final class MealImageClassifierTests: XCTestCase {

    func test_localize_knownFoods() {
        XCTAssertEqual(MealImageClassifier.localize("apple"), "苹果")
        XCTAssertEqual(MealImageClassifier.localize("pizza"), "披萨")
        XCTAssertEqual(MealImageClassifier.localize("PIZZA"), "披萨")
    }

    func test_localize_unknown_passesThroughWithUnderscoreReplaced() {
        XCTAssertEqual(MealImageClassifier.localize("hot_dog"), "热狗")
        // truly unknown:
        XCTAssertEqual(MealImageClassifier.localize("unobtainium_food"), "unobtainium food")
    }

    func test_classify_emptyImage_returnsEmptyArray() async {
        let empty = UIImage()
        let results = await MealImageClassifier.classify(image: empty)
        XCTAssertEqual(results, [])
    }
}
