import Limb
import Testing


@Suite struct Round2RequestStateBase64Tests {
    private let sealer = AEADRequestStateSealer(key: Array(repeating: 7, count: 32), keyID: "r2")

    private func isOpened(_ text: String) -> Bool { (try? sealer.open(text)) != nil }

    /// Sealed payloads of every length modulo 3, so that every Base64 tail occurs.
    @Test(arguments: 0..<9)
    func onlyCanonicalSpellingsOpen(length: Int) throws {
        let plaintext = (0..<(length * 7)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let sealed = try sealer.seal(plaintext)
        #expect(!sealed.contains("=") && !sealed.contains("+") && !sealed.contains("/"))
        #expect(try sealer.open(sealed) == plaintext)
        let tail = sealed.utf8.count % 4
        #expect(tail != 1)
        // Allowed: full padding; the standard alphabet throughout.
        let padding = String(repeating: "=", count: (4 - tail) % 4)
        #expect(isOpened(sealed + padding))
        let standard = String(sealed.map { $0 == "-" ? "+" : $0 == "_" ? "/" : $0 })
        #expect(isOpened(standard))
        // Refused: wrong padding.
        for wrong in ["=", "==", "==="] where wrong != padding {
            #expect(!isOpened(sealed + wrong), "\(sealed) + \(wrong)")
        }
        // Refused: unused low bits set in the last symbol.
        if tail != 0 {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            let last = sealed.last!
            let value = alphabet.firstIndex(of: last)!
            let unused = tail == 2 ? 0b1111 : 0b11
            #expect(value & unused == 0, "the sealer itself writes canonical text")
            let tweaked = String(sealed.dropLast()) + String(alphabet[value | 1])
            #expect(!isOpened(tweaked), "\(sealed) with its last symbol changed to \(alphabet[value | 1])")
            #expect(!isOpened(tweaked + padding))
        }
        // Refused: the two alphabets mixed. A URL-safe character turned into its standard
        // twin while others stay URL-safe, or a standard character added to a URL-safe string.
        let urlSafe = sealed.enumerated().filter { $0.element == "-" || $0.element == "_" }
        if urlSafe.count >= 2 {
            var characters = Array(sealed)
            let first = urlSafe[0].offset
            characters[first] = characters[first] == "-" ? "+" : "/"
            #expect(!isOpened(String(characters)), "mixed alphabets")
        }
        // Refused: anything outside the alphabet, and a truncation by one symbol.
        #expect(!isOpened(sealed + " "))
        #expect(!isOpened(" " + sealed))
        #expect(!isOpened(String(sealed.dropLast())))
    }
}
