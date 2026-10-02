import Foundation
import CoreGraphics

struct LiveDocumentSnapshot: Equatable {
    enum Phase: Equatable { case finding, aligning, positioning, steady, nextPage }
    var quad: ScanQuad?
    var phase: Phase = .finding
    var canAutoCapture: Bool { phase == .steady && quad != nil }
    var guidance: String {
        switch phase {
        case .finding: return "Place the whole page in view"
        case .aligning: return "Keep all four card edges visible"
        case .positioning: return "Hold steady"
        case .steady: return "Page detected · Ready to scan"
        case .nextPage: return "Move this page away before the next auto scan"
        }
    }
}

// Queue-confined, monotonic-time state. A capture remains latched until the sheet
// leaves view or the user explicitly chooses Add page. Foregrounding alone never
// releases it, so a stationary page cannot create a stream of duplicate scans.
struct LiveDocumentTracker {
    private var anchor: ScanQuad?
    private var displayed: ScanQuad?
    private var stableSince: TimeInterval?
    private var missingSince: TimeInterval?
    private var captured = false
    private(set) var snapshot = LiveDocumentSnapshot()
    let steadyDuration: TimeInterval = 0.8
    let releaseDuration: TimeInterval = 0.8

    mutating func update(_ candidate: ScanQuad?, at time: TimeInterval, eligible: Bool = true, requiredSteadyDuration: TimeInterval = 0.8, missingReleaseDuration: TimeInterval = 0.8) -> LiveDocumentSnapshot {
        guard let candidate, candidate.valid else {
            if missingSince == nil { missingSince = time }
            anchor = nil; stableSince = nil
            let missingFor = time - (missingSince ?? time)
            if missingFor >= 0.25 { displayed = nil }
            if missingFor >= missingReleaseDuration { captured = false }
            snapshot = LiveDocumentSnapshot(quad: displayed, phase: captured ? .nextPage : .finding)
            return snapshot
        }
        missingSince = nil
        if let previous = displayed {
            displayed = ScanQuad(points: zip(previous.points, candidate.points).map {
                ScanPoint(x: $0.x * 0.35 + $1.x * 0.65, y: $0.y * 0.35 + $1.y * 0.65)
            })
        } else { displayed = candidate }
        guard eligible else {
            anchor = nil; stableSince = nil
            snapshot = LiveDocumentSnapshot(quad: displayed, phase: captured ? .nextPage : .aligning)
            return snapshot
        }
        if anchor == nil || Self.movement(anchor!, candidate) > 0.018 {
            anchor = candidate; stableSince = time
        }
        let steady = time - (stableSince ?? time) >= requiredSteadyDuration
        snapshot = LiveDocumentSnapshot(quad: displayed, phase: captured ? .nextPage : (steady ? .steady : .positioning))
        return snapshot
    }

    mutating func markCapture() {
        captured = true
        snapshot.phase = .nextPage
    }

    mutating func clearPreview() {
        anchor = nil; displayed = nil; stableSince = nil; missingSince = nil
        snapshot = LiveDocumentSnapshot(quad: nil, phase: captured ? .nextPage : .finding)
    }

    mutating func beginNextPage() {
        captured = false
        clearPreview()
    }

    static func movement(_ a: ScanQuad, _ b: ScanQuad) -> Double {
        guard a.points.count == 4, b.points.count == 4 else { return .infinity }
        return zip(a.points, b.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? .infinity
    }

    // The rear-camera video output is physically rotated 90° clockwise into
    // portrait pixels. Preview-layer conversion takes unrotated sensor points.
    // The layer itself handles aspect-fill crop and its portrait connection.
    static func captureDevicePoint(fromPortrait point: ScanPoint) -> CGPoint {
        CGPoint(x: point.y, y: 1 - point.x)
    }
}
