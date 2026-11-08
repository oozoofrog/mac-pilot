import Foundation

struct PreviewMockState {
    enum Outcome: Int { case success, pending, failure, offline }
    var outcome = Outcome.success
    private(set) var generation = 0
    private(set) var confirmedAngle = 90.0
    private(set) var rotation = 0
    mutating func select(_ value: Outcome) { generation += 1; outcome = value }
    mutating func rotateFixture() { rotation = (rotation + 90) % 360 }
    mutating func setAngle(_ value: Double) { confirmedAngle = min(180, max(0, value.rounded())) }
    mutating func request() -> Int? {
        guard outcome != .offline else { return nil }
        generation += 1
        return generation
    }
    mutating func finish(_ token: Int, action: String, angle: Double?) -> Bool? {
        guard token == generation, outcome != .pending, outcome != .offline else { return nil }
        guard outcome == .success else { return false }
        if action == "rotate" { rotateFixture() }
        if action == "hinge", let angle { setAngle(angle) }
        return true
    }
}
