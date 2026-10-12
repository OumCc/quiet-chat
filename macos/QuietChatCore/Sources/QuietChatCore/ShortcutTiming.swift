// 快捷入口三段固定等待的配置值；只保存整数毫秒，不负责按键、焦点或打开结果。
// 每段限制在零与当前基准之间；无效值独立回退，实例创建后不可修改。

import Foundation

/** 单次搜索使用的不可变时序；保存或解码时保留有效阶段，其他阶段回退基准。 */
public struct ShortcutTiming: Codable, Equatable, Sendable {
    /** 打开搜索后等待，范围为 0...150 毫秒。 */
    public let searchOpenMs: Int
    /** 全选旧搜索词后等待，范围为 0...50 毫秒。 */
    public let selectAllMs: Int
    /** 输入名称后等待，范围为 0...500 毫秒。 */
    public let resultsMs: Int

    /** 当前基准为 150／50／500 毫秒，不表示已确认搜索控件就绪。 */
    public static let baseline = ShortcutTiming()

    /** 三段固定等待之和，不包含聚焦、系统调用或微信显示聊天的耗时。 */
    public var totalMs: Int { searchOpenMs + selectAllMs + resultsMs }

    /** 创建时序快照；越界值独立回退至该阶段基准，零值不跳过运行时身份校验。 */
    public init(searchOpenMs: Int = 150, selectAllMs: Int = 50, resultsMs: Int = 500) {
        self.searchOpenMs = Self.validated(searchOpenMs, baseline: 150)
        self.selectAllMs = Self.validated(selectAllMs, baseline: 50)
        self.resultsMs = Self.validated(resultsMs, baseline: 500)
    }

    /** 缺失或类型错误的阶段独立回退；对象类型错误交给 AppConfig 回退整组。 */
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            searchOpenMs: (try? container.decode(Int.self, forKey: .searchOpenMs)) ?? 150,
            selectAllMs: (try? container.decode(Int.self, forKey: .selectAllMs)) ?? 50,
            resultsMs: (try? container.decode(Int.self, forKey: .resultsMs)) ?? 500)
    }

    private static func validated(_ value: Int, baseline: Int) -> Int {
        (0...baseline).contains(value) ? value : baseline
    }
}
