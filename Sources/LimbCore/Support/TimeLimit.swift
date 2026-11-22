/// A time limit given in seconds by configuration, as a clock can use it: `nil` for no limit.
///
/// Zero, negative values and NaN mean "do not wait". Infinity means "wait as long as it takes",
/// and so does anything from about thirty years up: no process waits that long, and past it
/// clock arithmetic overflows (`Duration.seconds` and `Task.sleep` trap on such values).
package func timeLimit(seconds: Double) -> Duration? {
    guard seconds > 0 else { return .zero }
    guard seconds < 1e9 else { return nil }
    return .seconds(seconds)
}
