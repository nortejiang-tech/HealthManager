import Foundation

/// 指标明细页的展示数学（纯函数，无 UI 依赖）。
/// 独立成模块是为了让 y 轴等规则可单测——它们此前内嵌在 View 里，零测试。
enum MetricPresentation {

    /// 纵轴范围：取当前可见窗口内数据的最小/最大值并留白。
    ///
    /// - 柱状图必须包含 0 基线，否则条形溢出可视区、读成实心块；
    /// - 线/面积图自由浮动，取数据跨度 ±15% 留白；
    /// - 单一取值时按 ±5%（或 0.5 绝对值兜底）留白，让点落在图中间。
    ///
    /// 注意：传入的应是「当前可视窗口」的点，而非整段期间的点——
    /// 这样纵轴会随滚动/切换周期自适应，而不是锁定在全期间范围。
    static func yDomain(
        points: [MetricPoint],
        chartStyle: MetricDetailConfig.ChartStyle
    ) -> ClosedRange<Double> {
        let values = points.compactMap { $0.value }
        guard let mn = values.min(), let mx = values.max() else { return 0...1 }

        if chartStyle == .bar {
            let lo = min(0, mn)
            let hi = max(0, mx)
            let span = max(hi - lo, 1)
            let pad = span * 0.12
            return (lo == 0 ? 0 : lo - pad)...(hi == 0 ? 0 : hi + pad)
        }

        if mn == mx {
            let pad = max(abs(mn) * 0.05, 0.5)
            return (mn - pad)...(mx + pad)
        }
        let span = mx - mn
        let pad = span * 0.15
        return (mn - pad)...(mx + pad)
    }
}
