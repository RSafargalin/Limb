/// Standard and URL-safe base64, without Foundation.
public enum Base64 {
    private static let standard = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let urlSafe = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Encodes with padding (`urlSafe: false`) or without padding in the URL-safe alphabet.
    public static func encode(_ bytes: some Collection<UInt8>, urlSafe: Bool = false) -> String {
        let alphabet = urlSafe ? Base64.urlSafe : standard
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count + 2) / 3 * 4)
        var iterator = bytes.makeIterator()
        while let first = iterator.next() {
            let second = iterator.next()
            let third = iterator.next()
            let chunk = UInt32(first) << 16 | UInt32(second ?? 0) << 8 | UInt32(third ?? 0)
            output.append(alphabet[Int(chunk >> 18 & 0x3F)])
            output.append(alphabet[Int(chunk >> 12 & 0x3F)])
            if second != nil {
                output.append(alphabet[Int(chunk >> 6 & 0x3F)])
            } else if !urlSafe {
                output.append(0x3D)
            }
            if third != nil {
                output.append(alphabet[Int(chunk & 0x3F)])
            } else if !urlSafe {
                output.append(0x3D)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes the canonical spelling of some bytes in either alphabet, with full padding or
    /// none. Returns `nil` for anything else: characters outside the alphabet, both alphabets in
    /// one string, padding that does not match the length, or unused low bits that are not zero
    /// (`QR==` for "A", which is `QQ==`). So every byte string has exactly one accepted spelling
    /// per alphabet and padding style.
    public static func decode(_ text: String) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count / 4 * 3 + 3)
        var accumulator: UInt32 = 0
        var bits = 0
        var symbols = 0
        var padding = 0
        var standardOnly = false
        var urlSafeOnly = false
        for byte in text.utf8 {
            let value: UInt32
            switch byte {
            case 0x41...0x5A: value = UInt32(byte) - 0x41
            case 0x61...0x7A: value = UInt32(byte) - 0x61 + 26
            case 0x30...0x39: value = UInt32(byte) - 0x30 + 52
            case 0x2B, 0x2F:
                standardOnly = true
                value = byte == 0x2B ? 62 : 63
            case 0x2D, 0x5F:
                urlSafeOnly = true
                value = byte == 0x2D ? 62 : 63
            case 0x3D:
                padding += 1
                continue
            default: return nil
            }
            guard padding == 0 else { return nil }
            symbols += 1
            accumulator = accumulator << 6 | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
            }
        }
        // A final group of one symbol carries no whole byte; two carry one and three carry two,
        // padded to four with "=" or not at all.
        let tail = symbols % 4
        guard !(standardOnly && urlSafeOnly), tail != 1, padding == 0 || padding == (4 - tail) % 4 && tail != 0 else {
            return nil
        }
        guard accumulator & (1 << UInt32(bits) - 1) == 0 else { return nil }
        return output
    }
}
