import Foundation
import HealthKit

/// Single source of truth for which HealthKit types this app cares about.
///
/// Per PRD §4.1（不漏读原则）: 我们读取**类型全集**而不预过滤 source；归因在采集后由
/// `SourceAttribution` 决定。新增/删除指标只改这里一处。
enum HealthKitTypeCatalog {

    // MARK: - Identifiers grouped by domain (purely documentary; do not source-filter on these)

    /// 体重/身体成分。小米体脂秤通过 米家/小米运动健康 写入 Apple Health 后会出现在这里。
    static let bodyCompositionQuantities: [HKQuantityTypeIdentifier] = [
        .bodyMass,
        .bodyFatPercentage,
        .bodyMassIndex,
        .leanBodyMass,
        .basalEnergyBurned,
        .height
    ]

    /// 活动 / 能量。Garmin / Apple Watch / iPhone 协同写入。
    static let activityQuantities: [HKQuantityTypeIdentifier] = [
        .stepCount,
        .distanceWalkingRunning,
        .activeEnergyBurned,
        .flightsClimbed,
        .appleExerciseTime,
        .appleStandTime
    ]

    /// 心血管 / 呼吸。Garmin、Apple Watch 等。
    static let cardioQuantities: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .restingHeartRate,
        .heartRateVariabilitySDNN,
        .vo2Max,
        .oxygenSaturation,
        .respiratoryRate,
        .bloodPressureSystolic,
        .bloodPressureDiastolic,
        .bodyTemperature
    ]

    /// 饮食。承接 F-003 的手动录入与未来 AI 识别。
    static let nutritionQuantities: [HKQuantityTypeIdentifier] = [
        .dietaryEnergyConsumed,
        .dietaryProtein,
        .dietaryFatTotal,
        .dietaryCarbohydrates,
        .dietaryWater
    ]

    static var allQuantityIdentifiers: [HKQuantityTypeIdentifier] {
        bodyCompositionQuantities + activityQuantities + cardioQuantities + nutritionQuantities
    }

    static let categoryIdentifiers: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis
    ]

    // MARK: - Sample types

    static var allQuantityTypes: [HKQuantityType] {
        allQuantityIdentifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
    }

    static var allCategoryTypes: [HKCategoryType] {
        categoryIdentifiers.compactMap { HKCategoryType.categoryType(forIdentifier: $0) }
    }

    static var workoutType: HKWorkoutType { HKWorkoutType.workoutType() }

    /// All sample types we want to *read* from HealthKit. Used for both authorization
    /// and the per-type iteration in Backfill / Anchored queries.
    static var allReadSampleTypes: [HKSampleType] {
        var list: [HKSampleType] = []
        list.append(contentsOf: allQuantityTypes as [HKSampleType])
        list.append(contentsOf: allCategoryTypes as [HKSampleType])
        list.append(workoutType)
        return list
    }

    static var allReadObjectTypes: Set<HKObjectType> {
        Set(allReadSampleTypes.map { $0 as HKObjectType })
    }

    /// Dietary quantity types we write back to Apple Health from the app's diet log,
    /// so Health can record and aggregate nutrition the app captured (photo / 文字 / 手动).
    static let nutritionWriteIdentifiers: [HKQuantityTypeIdentifier] = [
        .dietaryEnergyConsumed,
        .dietaryProtein,
        .dietaryFatTotal,
        .dietaryCarbohydrates
    ]

    static var nutritionWriteSampleTypes: [HKQuantityType] {
        nutritionWriteIdentifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
    }

    /// The `.food` correlation type — lets us group a meal's macros into one Apple Health
    /// entry (a "meal") instead of four loose nutrient samples.
    static var foodCorrelationType: HKCorrelationType? {
        HKCorrelationType.correlationType(forIdentifier: .food)
    }

    /// Types the app requests *share* (write) permission for: the dietary macros plus the
    /// food correlation that bundles them into a single meal.
    static var writeSampleTypes: Set<HKSampleType> {
        var set = Set(nutritionWriteSampleTypes.map { $0 as HKSampleType })
        if let food = foodCorrelationType { set.insert(food) }
        return set
    }

    // MARK: - Canonical units

    /// Preferred storage unit per quantity identifier. Storing in a canonical unit means
    /// downstream queries can compare values without re-reading the unit string each time.
    static func preferredUnit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
        switch identifier {
        case .bodyMass, .leanBodyMass:
            return .gramUnit(with: .kilo)
        case .bodyFatPercentage, .oxygenSaturation:
            return .percent()
        case .bodyMassIndex:
            return .count()
        case .basalEnergyBurned, .activeEnergyBurned, .dietaryEnergyConsumed:
            return .kilocalorie()
        case .height:
            return .meter()
        case .stepCount, .flightsClimbed:
            return .count()
        case .distanceWalkingRunning:
            return .meter()
        case .appleExerciseTime, .appleStandTime:
            return .minute()
        case .heartRate, .restingHeartRate, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN:
            return .secondUnit(with: .milli)
        case .vo2Max:
            return HKUnit(from: "ml/(kg*min)")
        case .bloodPressureSystolic, .bloodPressureDiastolic:
            return .millimeterOfMercury()
        case .bodyTemperature:
            return .degreeCelsius()
        case .dietaryProtein, .dietaryFatTotal, .dietaryCarbohydrates:
            return .gram()
        case .dietaryWater:
            return .literUnit(with: .milli)
        default:
            return .count()
        }
    }

    static func preferredUnit(for type: HKQuantityType) -> HKUnit {
        guard let id = HKQuantityTypeIdentifier(rawValue: type.identifier) as HKQuantityTypeIdentifier? else {
            return .count()
        }
        return preferredUnit(for: id)
    }
}
