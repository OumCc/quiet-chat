// 解锁密码：默认密码与用户自定义密码的校验。
// 自定义密码只保存 PBKDF2-SHA256 哈希和随机盐，不存明文；字段格式见 shared/config.schema.json 的 password。
// Windows 端用 Rfc2898DeriveBytes.Pbkdf2 按同样的参数计算，结果一致。

import CommonCrypto
import Foundation

/// 保存在配置里的自定义密码。
public struct PasswordRecord: Codable, Equatable, Sendable {
    public static let algorithmName = "PBKDF2-SHA256"

    public var algorithm: String
    public var iterations: Int
    /// Base64 编码的随机盐。
    public var salt: String
    /// Base64 编码的派生结果。
    public var hash: String

    public init(algorithm: String = Self.algorithmName, iterations: Int, salt: String, hash: String) {
        self.algorithm = algorithm
        self.iterations = iterations
        self.salt = salt
        self.hash = hash
    }
}

/// 密码校验与生成。
public enum PasswordVerifier {
    /// 没有设置过密码时使用的默认密码。
    public static let defaultPassword = "1234567890"
    /// 新密码的迭代次数、盐长度和结果长度（字节）。
    static let iterations = 100_000
    static let saltLength = 16
    static let hashLength = 32

    /// 校验输入的密码；`record` 为 nil（从未改过密码）时与默认密码比较。
    public static func verify(_ password: String, against record: PasswordRecord?) -> Bool {
        guard let record else { return password == defaultPassword }
        guard record.algorithm == PasswordRecord.algorithmName, record.iterations > 0,
              let salt = Data(base64Encoded: record.salt), let expected = Data(base64Encoded: record.hash),
              let actual = derive(password, salt: salt, iterations: record.iterations, length: expected.count)
        else { return false }
        return constantTimeEquals(actual, expected)
    }

    /// 为新密码生成记录；派生失败时返回 nil。
    public static func makeRecord(for password: String) -> PasswordRecord? {
        // SystemRandomNumberGenerator 在 Apple 平台上是密码学安全的随机源
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: .min ... .max) })
        guard let hash = derive(password, salt: salt, iterations: iterations, length: hashLength) else { return nil }
        return PasswordRecord(iterations: iterations, salt: salt.base64EncodedString(), hash: hash.base64EncodedString())
    }

    /// PBKDF2-HMAC-SHA256，密码按 UTF-8 编码。
    static func derive(_ password: String, salt: Data, iterations: Int, length: Int) -> Data? {
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    derivedBytes.bindMemory(to: UInt8.self).baseAddress, length)
            }
        }
        return status == Int32(kCCSuccess) ? derived : nil
    }

    // 逐字节比较完再出结果，耗时不随第一个不同字节的位置变化
    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
