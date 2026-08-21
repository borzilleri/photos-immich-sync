import Testing

@testable import PhotosImmichSyncCore

@Suite struct LoggingTests {
  @Test(arguments: [
    (false, -3, Verbosity.normal),
    (false, 0, .normal),
    (false, 1, .verbose),
    (false, 2, .debug),
    (false, 3, .trace),
    (false, 99, .trace),
    (true, 0, .quiet),
    (true, 3, .quiet),  // quiet wins over verbose
  ])
  func verbosityFromFlags(quiet: Bool, verbose: Int, expected: Verbosity) {
    #expect(Verbosity.fromFlags(quiet: quiet, verbose: verbose) == expected)
  }

  @Test func verbosityOrdering() {
    #expect(Verbosity.quiet < .normal)
    #expect(Verbosity.normal < .verbose)
    #expect(Verbosity.verbose < .debug)
    #expect(Verbosity.debug < .trace)
  }

  @Test func runSummaryFlags() {
    #expect(!RunSummary(errors: 0, warnings: 0).hasErrors)
    #expect(!RunSummary(errors: 0, warnings: 0).hasWarnings)
    #expect(RunSummary(errors: 1, warnings: 0).hasErrors)
    #expect(RunSummary(errors: 0, warnings: 2).hasWarnings)
  }
}
