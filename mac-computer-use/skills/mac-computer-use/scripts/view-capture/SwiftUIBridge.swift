import Foundation
import SwiftUI
import UIKit

// Generic adapter compiled into the pinned resident image.
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
@objc(MacCUSwiftUIBridge)
public final class MacCUSwiftUIBridge: NSObject {
    @objc public static func accepts(_ view: UIView) -> Bool {
        view is any ExternalDebugSource
    }

    @objc public static func graph(_ view: UIView) -> NSData? {
        guard let source = view as? any ExternalDebugSource else { return nil }
        return source.externalDebugBytes() as NSData?
    }
}
