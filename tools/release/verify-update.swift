// 发布门禁：用应用内公钥验证完整归档，核对清单版本和系统要求，防止发布错误密钥或元数据。
// 清单自身的签名由 Sparkle sign_update --verify 验证；这里不重新实现其 XML 签名协议。

import CryptoKit
import Foundation

final class AppcastMetadata: NSObject, XMLParserDelegate {
    var itemCount = 0
    var fields: [String: String] = [:]
    var enclosure: [String: String] = [:]
    private var activeField: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "item" { itemCount += 1 }
        if name == "enclosure" { enclosure = attributes }
        if ["sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion"].contains(name) {
            activeField = name
            fields[name] = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard let field = activeField else { return }
        fields[field, default: ""] += text
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == activeField { activeField = nil }
    }
}

enum VerificationError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let message): return message }
    }
}

func verify(app: URL, archive: URL, feed: URL) throws {
    let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil)
    guard let properties = info as? [String: Any],
          let key = properties["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: key), keyData.count == 32,
          let version = properties["CFBundleVersion"] as? String,
          let displayVersion = properties["CFBundleShortVersionString"] as? String,
          let minimumSystem = properties["LSMinimumSystemVersion"] as? String else {
        throw VerificationError.invalid("应用版本、最低系统版本或更新公钥缺失")
    }
    let metadata = AppcastMetadata()
    let parser = XMLParser(data: try Data(contentsOf: feed))
    parser.shouldResolveExternalEntities = false
    parser.delegate = metadata
    guard parser.parse(), metadata.itemCount == 1,
          metadata.fields["sparkle:version"]?.trimmingCharacters(in: .whitespacesAndNewlines) == version,
          metadata.fields["sparkle:shortVersionString"]?.trimmingCharacters(in: .whitespacesAndNewlines) == displayVersion,
          metadata.fields["sparkle:minimumSystemVersion"]?.trimmingCharacters(in: .whitespacesAndNewlines) == minimumSystem,
          let signature = metadata.enclosure["sparkle:edSignature"].flatMap({ Data(base64Encoded: $0) }),
          let length = metadata.enclosure["length"].flatMap(Int.init),
          let url = metadata.enclosure["url"].flatMap(URL.init(string:)),
          url.lastPathComponent == archive.lastPathComponent else {
        throw VerificationError.invalid("清单条目、版本、系统要求或归档属性不匹配")
    }
    let payload = try Data(contentsOf: archive, options: .mappedIfSafe)
    guard payload.count == length,
          try Curve25519.Signing.PublicKey(rawRepresentation: keyData).isValidSignature(signature, for: payload) else {
        throw VerificationError.invalid("归档长度或 EdDSA 签名无效，或发布私钥与客户端公钥不匹配")
    }
    print("更新归档、公钥与清单元数据验证通过：\(displayVersion) (\(version))")
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw VerificationError.invalid("用法：swift verify-update.swift <app> <archive> <appcast.xml>")
    }
    try verify(app: URL(fileURLWithPath: CommandLine.arguments[1]),
               archive: URL(fileURLWithPath: CommandLine.arguments[2]),
               feed: URL(fileURLWithPath: CommandLine.arguments[3]))
} catch {
    FileHandle.standardError.write(Data("更新验证失败：\(error)\n".utf8))
    exit(1)
}
