import Foundation

/// SHA-1, used for UUIDv5 recipe ids and cache keys (not for security).
/// Implemented here because CryptoKit isn't available on Linux.
public enum SHA1 {
    public static func digest(_ data: Data) -> [UInt8] {
        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xFF)) }

        var w = [UInt32](repeating: 0, count: 80)
        message.withUnsafeBufferPointer { buf in
            for chunk in stride(from: 0, to: buf.count, by: 64) {
                for i in 0..<16 {
                    let b = chunk + i * 4
                    w[i] = UInt32(buf[b]) << 24 | UInt32(buf[b + 1]) << 16 | UInt32(buf[b + 2]) << 8 | UInt32(buf[b + 3])
                }
                for i in 16..<80 {
                    let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                    w[i] = (x << 1) | (x >> 31)
                }
                var a = h0, b = h1, c = h2, d = h3, e = h4
                for i in 0..<80 {
                    let f: UInt32, k: UInt32
                    switch i {
                    case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                    case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                    case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                    default: f = b ^ c ^ d; k = 0xCA62C1D6
                    }
                    let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                    e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
                }
                h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
            }
        }
        var out: [UInt8] = []
        for h in [h0, h1, h2, h3, h4] { for s in [24, 16, 8, 0] { out.append(UInt8((h >> UInt32(s)) & 0xFF)) } }
        return out
    }

    public static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(_ string: String) -> String { hex(Data(string.utf8)) }
}

public enum UUIDv5 {
    /// The namespace for recipe ids made by this app.
    public static let recipeNamespace = UUID(uuidString: "6F1C3A52-8E0B-4C55-9B57-3E1A2F0D9C41")!

    public static func make(namespace: UUID, name: String) -> UUID {
        let ns = namespace.uuid
        var bytes = [ns.0, ns.1, ns.2, ns.3, ns.4, ns.5, ns.6, ns.7, ns.8, ns.9, ns.10, ns.11, ns.12, ns.13, ns.14, ns.15]
        bytes.append(contentsOf: Array(name.utf8))
        var d = SHA1.digest(Data(bytes))
        d[6] = (d[6] & 0x0F) | 0x50
        d[8] = (d[8] & 0x3F) | 0x80
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }
}
