import Foundation
@main struct FeedbackStoreCheck {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.jsonl")
        try appendPreviewFeedback(["comment":"각도 \"89°\"\n확인", "viewChainTargetFirst":[["class":"Fixture"]]],to: file)
        try appendPreviewFeedback(["comment":"두 번째"],to: file)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        precondition(lines.count == 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String:Any]
        precondition(first["comment"] as? String == "각도 \"89°\"\n확인")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do { try appendPreviewFeedback(["comment":"not written"],to: link); fatalError("symlink accepted") } catch {}
        let final = try String(contentsOf: file,encoding: .utf8)
        precondition(final.split(separator: "\n").count == 2)
        print("PASS local feedback append, Unicode/newlines, target association and symlink rejection")
    }
}
