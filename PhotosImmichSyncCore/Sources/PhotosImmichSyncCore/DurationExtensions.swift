import NIOCore

extension Duration {
  /// Converts a Swift `Duration` into a NIO `TimeAmount`, saturating at `Int64.max`
  /// nanoseconds so that a large timeout cannot overflow.
  func toTimeAmount() -> TimeAmount {
    let (seconds, attoseconds) = self.components
    let nanosFromAtto = attoseconds / 1_000_000_000
    let (mul, mulOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    if mulOverflow { return .nanoseconds(.max) }
    let (sum, sumOverflow) = mul.addingReportingOverflow(nanosFromAtto)
    if sumOverflow { return .nanoseconds(.max) }
    return .nanoseconds(sum)
  }
}
