import AppKit

/// `pointInParent` is in the coordinate system required by NSView.hitTest.
func previewHitTarget(root: NSView, pointInParent: NSPoint) -> NSView? {
    root.hitTest(pointInParent)
}

func previewViewChain(target: NSView, root: NSView) -> [[String: Any]] {
    var chain: [[String: Any]] = []
    var current: NSView? = target
    while let view = current {
        let frame = view.convert(view.bounds, to: nil)
        var item: [String: Any] = ["class": NSStringFromClass(type(of: view)),
                                  "frameInWindow": [frame.origin.x, frame.origin.y, frame.width, frame.height]]
        if let label = view.accessibilityLabel(), !label.isEmpty { item["accessibilityLabel"] = label }
        if let identifier = view.identifier?.rawValue, !identifier.isEmpty { item["identifier"] = identifier }
        if let parent = view.superview, let index = parent.subviews.firstIndex(of: view) { item["siblingIndex"] = index }
        chain.append(item)
        if view === root { break }
        current = view.superview
    }
    return chain
}
