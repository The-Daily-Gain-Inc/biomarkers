import Foundation
import Security

/// RSA/PKCS1-v1.5 encryption of the Renpho password with Renpho's public
/// key (the unofficial qnclouds cloud API expects the password encrypted
/// this way, base64-encoded).
enum RenphoCrypto {
    // Renpho's 1024-bit RSA public key (SubjectPublicKeyInfo PEM).
    private static let publicKeyPEM = """
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC+25I2upukpfQ7rIaaTZtVE744\
    u2zV+HaagrUhDOTq8fMVf9yFQvEZh2/HKxFudUxP0dXUa8F6X4XmWumHdQnum3zm\
    Jr04fz2b2WCcN0ta/rbF2nYAnMVAk2OJVZAMudOiMWhcxV1nNJiKgTNNr13de0EQ\
    IiOL2CUBzu+HmIfUbQIDAQAB
    """

    /// Base64 of PKCS1-v1.5(password) or nil on failure.
    static func encryptPassword(_ password: String) -> String? {
        guard let key = publicKey(),
              let encrypted = SecKeyCreateEncryptedData(
                key, .rsaEncryptionPKCS1, Data(password.utf8) as CFData, nil) as Data?
        else { return nil }
        return encrypted.base64EncodedString()
    }

    private static func publicKey() -> SecKey? {
        guard let spki = Data(base64Encoded: publicKeyPEM.replacingOccurrences(of: "\n", with: "")),
              let pkcs1 = pkcs1(fromSPKI: [UInt8](spki))
        else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        return SecKeyCreateWithData(Data(pkcs1) as CFData, attrs as CFDictionary, nil)
    }

    /// SecKeyCreateWithData wants the bare PKCS1 RSAPublicKey; strip the
    /// SPKI wrapper (SEQUENCE { AlgorithmIdentifier, BIT STRING { PKCS1 } }).
    private static func pkcs1(fromSPKI der: [UInt8]) -> [UInt8]? {
        var i = 0
        guard let seq = readTLV(der, &i), seq.tag == 0x30 else { return nil }
        var j = seq.start
        guard let alg = readTLV(der, &j), alg.tag == 0x30 else { return nil }
        j = alg.start + alg.len
        guard let bits = readTLV(der, &j), bits.tag == 0x03, bits.len > 1 else { return nil }
        // First BIT STRING content byte is the unused-bits count (0x00).
        return Array(der[(bits.start + 1)..<(bits.start + bits.len)])
    }

    private static func readTLV(_ data: [UInt8], _ i: inout Int) -> (tag: UInt8, start: Int, len: Int)? {
        guard i < data.count else { return nil }
        let tag = data[i]; i += 1
        guard i < data.count else { return nil }
        var len = Int(data[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7f
            len = 0
            for _ in 0..<n {
                guard i < data.count else { return nil }
                len = (len << 8) | Int(data[i]); i += 1
            }
        }
        let start = i
        return (tag, start, len)
    }
}
