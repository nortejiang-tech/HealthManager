import Foundation
import UIKit
import Vision

/// Best-effort image classifier for meal photos.
///
/// Uses `VNClassifyImageRequest`, Apple's built-in image label model (Imagenet-style).
/// Quality varies — works great on common single-item foods (apple, pizza, coffee),
/// less well on plated meals. We surface top-K confident labels as a suggestion;
/// user always retains free-form notes editing.
///
/// English labels are mapped through a small Chinese dictionary for the obvious foods;
/// anything else passes through as-is. Not a nutrition oracle — just a hint.
enum MealImageClassifier {

    struct Suggestion: Equatable {
        let label: String        // localized when known
        let confidence: Float    // 0...1
    }

    /// Returns up to `limit` suggestions whose confidence ≥ `minConfidence`.
    /// Returns empty array (not throws) on any Vision failure; this is a UX hint, not a hard contract.
    static func classify(image: UIImage, limit: Int = 3, minConfidence: Float = 0.15) async -> [Suggestion] {
        guard let cgImage = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            // Run off the calling actor — Vision blocks otherwise.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNClassifyImageRequest { request, _ in
                    let observations = (request.results as? [VNClassificationObservation]) ?? []
                    let filtered = observations
                        .filter { $0.confidence >= minConfidence }
                        .prefix(limit)
                    let mapped = filtered.map { obs in
                        Suggestion(label: localize(obs.identifier), confidence: obs.confidence)
                    }
                    continuation.resume(returning: Array(mapped))
                }
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// English → Chinese for a curated common-food vocabulary.
    /// Unknown identifiers pass through as-is.
    private static let zh: [String: String] = [
        "apple": "苹果",
        "banana": "香蕉",
        "orange": "橙子",
        "pear": "梨",
        "grape": "葡萄",
        "strawberry": "草莓",
        "watermelon": "西瓜",
        "pineapple": "菠萝",
        "pizza": "披萨",
        "hamburger": "汉堡",
        "hot_dog": "热狗",
        "french_fries": "薯条",
        "sandwich": "三明治",
        "salad": "沙拉",
        "soup": "汤",
        "noodle": "面条",
        "rice": "米饭",
        "bread": "面包",
        "donut": "甜甜圈",
        "cake": "蛋糕",
        "ice_cream": "冰淇淋",
        "coffee": "咖啡",
        "tea": "茶",
        "beer": "啤酒",
        "wine": "葡萄酒",
        "milk": "牛奶",
        "egg": "鸡蛋",
        "chicken": "鸡肉",
        "beef": "牛肉",
        "pork": "猪肉",
        "fish": "鱼",
        "shrimp": "虾",
        "broccoli": "西兰花",
        "carrot": "胡萝卜",
        "tomato": "番茄",
        "potato": "土豆",
        "lemon": "柠檬",
        "avocado": "牛油果",
        "sushi": "寿司",
        "dumpling": "饺子",
        "pasta": "意面"
    ]

    static func localize(_ identifier: String) -> String {
        zh[identifier.lowercased()] ?? identifier.replacingOccurrences(of: "_", with: " ")
    }
}
