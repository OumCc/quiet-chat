// 快捷入口三段固定等待的配置值；只保存整数毫秒，不负责按键、焦点或打开结果。
// 每段有独立上限，默认和无效值均为零；实例创建后不可修改。

import Foundation

/** 单次搜索使用的不可变时序；保存或解码时保留有效阶段，其他阶段回退基准。 */
public struct ShortcutTiming: Codable, Equatable, Sendable {
    /** 打开搜索后等待，范围为 0...150 毫秒。 */
    public let searchOpenMs: Int
    /** 全选旧搜索词后等待，范围为 0...50 毫秒。 */
    public let selectAllMs: Int
    /** 输入名称后等待，范围为 0...500 毫秒。 */
    public let resultsMs: Int

    /** 打开搜索的自定义范围，不随零等待基准变化。 */
    public static let searchOpenRange = 0...150
    /** 全选旧搜索词的自定义范围，不随零等待基准变化。 */
    public static let selectAllRange = 0...50
    /** 等待搜索结果的自定义范围，不随零等待基准变化。 */
    public static let resultsRange = 0...500

    /** 当前基准为三段零等待，不表示已确认搜索控件就绪。 */
    public static let baseline = ShortcutTiming()

    /** 三段固定等待之和，不包含聚焦、系统调用或微信显示聊天的耗时。 */
    public var totalMs: Int { searchOpenMs + selectAllMs + resultsMs }

    /** 创建时序快照；越界值独立回退至该阶段基准，零值不跳过运行时身份校验。 */
    public init(searchOpenMs: Int = 0, selectAllMs: Int = 0, resultsMs: Int = 0) {
        self.searchOpenMs = Self.validated(searchOpenMs, range: Self.searchOpenRange)
        self.selectAllMs = Self.validated(selectAllMs, range: Self.selectAllRange)
        self.resultsMs = Self.validated(resultsMs, range: Self.resultsRange)
    }

    /** 缺失或类型错误的阶段独立回退；对象类型错误交给 AppConfig 回退整组。 */
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            searchOpenMs: (try? container.decode(Int.self, forKey: .searchOpenMs)) ?? 0,
            selectAllMs: (try? container.decode(Int.self, forKey: .selectAllMs)) ?? 0,
            resultsMs: (try? container.decode(Int.self, forKey: .resultsMs)) ?? 0)
    }

    private static func validated(_ value: Int, range: ClosedRange<Int>) -> Int {
        range.contains(value) ? value : 0
    }
}
