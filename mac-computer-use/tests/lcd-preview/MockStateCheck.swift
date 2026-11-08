import Foundation
@main struct MockStateCheck {
    static func main() {
        var state = PreviewMockState()
        let first = state.request()!
        precondition(state.rotation == 0 && state.finish(first,action: "rotate",angle: nil) == true && state.rotation == 90)
        state.select(.failure)
        let fail = state.request()!
        precondition(state.finish(fail,action: "hinge",angle: 33) == false && state.confirmedAngle == 90)
        state.select(.pending)
        let pending = state.request()!
        precondition(state.finish(pending,action: "hinge",angle: 33) == nil && state.confirmedAngle == 90)
        state.select(.success)
        precondition(state.finish(pending,action: "hinge",angle: 33) == nil)
        let retry = state.request()!
        precondition(state.finish(retry,action: "hinge",angle: 89) == true && state.confirmedAngle == 89)
        state.select(.offline)
        precondition(state.request() == nil && state.confirmedAngle == 89)
        print("PASS mock request/confirmation, pending, failure, retry, stale completion and offline")
    }
}
