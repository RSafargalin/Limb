#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension ServerConfiguration {
    /// Writes one line to stderr. On stdio transports stdout carries only protocol messages.
    public static let standardErrorDiagnostics: @Sendable (String) -> Void = { message in
        var line = Array("limb: \(message)\n".utf8)
        line.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(2, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }
}

/// Text a peer sent, as it may appear in a diagnostic: control characters escaped, so that it
/// cannot forge a line of its own or drive a terminal, and at most `limit` characters as
/// written — escapes included — plus the "…" that marks a cut.
func peerText(_ text: String, limit: Int = 128) -> String {
    var result = ""
    var count = 0
    for scalar in text.unicodeScalars {
        let escaped: Bool
        switch scalar.value {
        // Line and paragraph separators end a line in some viewers.
        case 0x2028, 0x2029: escaped = true
        case 0x20..<0x7F, 0xA0...: escaped = false
        default: escaped = true
        }
        let piece = escaped ? "\\u{" + String(scalar.value, radix: 16) + "}" : String(scalar)
        let length = escaped ? piece.utf8.count : 1
        guard count + length <= limit else {
            result += "…"
            break
        }
        result += piece
        count += length
    }
    return result
}

/// A whole diagnostic, escaped like `peerText` and shortened to a line a terminal can take.
func diagnosticLine(_ text: String) -> String {
    peerText(text, limit: 2048)
}

/// Seconds since the Unix epoch.
func unixTime() -> Int {
    var now = timespec()
    clock_gettime(CLOCK_REALTIME, &now)
    return Int(now.tv_sec)
}
