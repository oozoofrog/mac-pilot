import AppKit
@main struct FeedbackTargetCheck {
    static func main() {
        let root = NSView(frame: NSRect(x: 10,y: 20,width: 300,height: 300))
        root.identifier = NSUserInterfaceItemIdentifier("root")
        let back = NSView(frame: NSRect(x: 20,y: 30,width: 150,height: 150))
        let front = NSView(frame: NSRect(x: 40,y: 50,width: 100,height: 100))
        front.identifier = NSUserInterfaceItemIdentifier("front")
        root.addSubview(back); root.addSubview(front)
        let leaf = NSView(frame: NSRect(x: 10,y: 10,width: 20,height: 20))
        leaf.identifier = NSUserInterfaceItemIdentifier("leaf"); front.addSubview(leaf)
        let point = NSPoint(x: 10+40+15,y: 20+50+15)
        guard let hit = previewHitTarget(root: root, pointInParent: point) else { fatalError("missing hit") }
        precondition(hit === leaf, "hit must select deepest frontmost view")
        let chain = previewViewChain(target: hit,root: root)
        precondition(chain.compactMap { $0["identifier"] as? String } == ["leaf","front","root"])
        precondition(chain.count == 3 && chain[0]["siblingIndex"] as? Int == 0 && chain[1]["siblingIndex"] as? Int == 1)
        precondition(previewHitTarget(root: root,pointInParent: NSPoint(x: 0,y: 0)) == nil)
        print("PASS precise frontmost nested hit and target-to-root identity path")
    }
}
