import Foundation
import CommonCrypto

/// The current Renpho Health cloud API (cloud.renpho.com) encrypts every
/// request/response payload with AES-128-ECB + PKCS7, base64-encoded, under
/// a fixed app key. Requests are wrapped as {"encryptData": "<base64>"}; the
/// password travels in plaintext *inside* that encrypted JSON.
enum RenphoCrypto {
    private static let key = Data("ed*wijdi$h6fe3ew".utf8)   // 16-byte AES-128 key

    /// {"encryptData": base64(AES-ECB(compact-json(obj)))}
    static func encryptRequest(_ obj: Any) -> [String: String]? {
        guard let json = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let enc = aes(json, operation: kCCEncrypt)
        else { return nil }
        return ["encryptData": enc.base64EncodedString()]
    }

    /// Decrypts a response `data` field (base64 AES-ECB) and parses JSON.
    static func decryptResponse(_ base64: String) -> Any? {
        guard let cipher = Data(base64Encoded: base64),
              let plain = aes(cipher, operation: kCCDecrypt)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: plain, options: [.fragmentsAllowed])
    }

    private static func aes(_ input: Data, operation: Int) -> Data? {
        let bufSize = input.count + kCCBlockSizeAES128
        var buf = Data(count: bufSize)
        var moved = 0
        let status = buf.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    CCCrypt(
                        CCOperation(operation),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        k.baseAddress, key.count,
                        nil,
                        inp.baseAddress, input.count,
                        out.baseAddress, bufSize,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return buf.prefix(moved)
    }
}
