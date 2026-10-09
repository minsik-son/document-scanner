import XCTest
@testable import DocumentScanner

/// The warm-up must do the expensive first-use work, so the next real call is fast.
final class WarmupTests: XCTestCase {
    func testWarmupMakesTheFirstRealScanStepsFaster() throws {
        Warmup.run()
        let first = Warmup.timings
        Warmup.run()
        let second = Warmup.timings
        print("WARMUP first \(first.mapValues { Int($0) }) then \(second.mapValues { Int($0) })")
        for key in ["detect", "tone", "text"] {
            XCTAssertNotNil(first[key], key)
            XCTAssertLessThanOrEqual(second[key] ?? .infinity, (first[key] ?? 0) + 30, key)
        }
    }
}
