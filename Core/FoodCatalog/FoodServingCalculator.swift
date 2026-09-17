import Foundation

/// 目录条目的份量换算（验收 A04/A06）。
///
/// - 同状态比例缩放：每 100 g → X g，各营养素按 X/100 放大，保持双精度原精度、
///   仅展示层舍入。
/// - 0 / 负数 / 非有限重量一律拒绝（返回 nil），不得静默当 0 g 处理。
/// - 未测定（unmeasured）与微量（trace）不参与缩放——它们不是 0。
/// - 饮料（per100mL）按体积口径换算，不得当作 100 g 生成伪重量值。
enum FoodServingCalculator {

    static func validGrams(_ raw: Double) -> Bool {
        raw.isFinite && raw > 0
    }

    /// 把「每 100 单位（g/mL）」的值缩放到指定份量。
    /// 返回 nil 表示份量非法；营养素本身缺失时原样保留缺失语义。
    static func scaled(_ nutrient: FoodCatalogNutrient, serving: Double) -> FoodCatalogNutrient? {
        guard validGrams(serving) else { return nil }
        guard let value = nutrient.value else { return nutrient }
        let scaledValue = value * serving / 100
        return FoodCatalogNutrient(value: scaledValue, flag: nutrient.flag)
    }

    /// 整组营养素换算。serving 非法时整体返回 nil。
    static func scaled(_ nutrients: FoodCatalogEntry.Nutrients, serving: Double) -> FoodCatalogEntry.Nutrients? {
        guard validGrams(serving) else { return nil }
        func s(_ n: FoodCatalogNutrient) -> FoodCatalogNutrient {
            scaled(n, serving: serving) ?? n
        }
        return FoodCatalogEntry.Nutrients(
            kcal: s(nutrients.kcal),
            proteinG: s(nutrients.proteinG),
            fatG: s(nutrients.fatG),
            carbsG: s(nutrients.carbsG),
            fiberG: s(nutrients.fiberG),
            sodiumMg: s(nutrients.sodiumMg)
        )
    }
}
