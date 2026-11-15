import Foundation
import SwiftUI
import UIKit

// This module never imports, names or links the fixture's concrete Content.
@MainActor
protocol ExternalDebugSource {
    func externalDebugBytes() -> Data?
}

extension _UIHostingView: ExternalDebugSource {
    func externalDebugBytes() -> Data? {
        _ViewDebug.serializedData(_viewDebugData())
    }
}

@MainActor
@objc(SwiftUIProbeBridge)
public final class SwiftUIProbeBridge: NSObject {
    @objc public static func accepts(_ view: UIView) -> Bool {
        view is any ExternalDebugSource
    }

    @objc public static func graph(_ view: UIView) -> NSData? {
        guard let source = view as? any ExternalDebugSource else { return nil }
        return source.externalDebugBytes() as NSData?
    }
}
