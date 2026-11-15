import AppKit
struct ToolError: Error { init(_ message: String) {} }
struct ActiveScreen { var points: CGSize = .zero; var unrotated: CGSize = .zero; var guestRotation = ""; func shown(_ r: CGRect) -> CGRect { r }; func presentingGuestFrame(_ r: CGRect) -> CGRect { r } }
func screenSize(of: NSObject) -> CGSize { .zero }
func udid(of: NSObject) -> String { "fake" }
class HIDLink { func touch(_ p: CGPoint, phase: Int, screen: ActiveScreen?) {} }
struct StubSession { var requestCancelled = false }; var currentSession: StubSession?
func simulatorPasteSelectionIsValid(_ range: NSRange, value: String) -> Bool { true }
func runSimulatorGesture(arguments: [String: Any], device: NSObject, screen: ActiveScreen?, cancelled: () -> Bool) throws -> Bool { false }
