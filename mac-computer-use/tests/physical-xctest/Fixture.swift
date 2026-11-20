import SwiftUI

@main struct Fixture: App {
    @State private var saved = false
    @State private var name = ""
    var body: some Scene {
        WindowGroup {
            VStack {
                TextField("Name", text: $name).accessibilityIdentifier("name")
                SecureField("Secret", text: .constant("")).accessibilityIdentifier("secret")
                Text(name).accessibilityIdentifier("echo")
                Button("Save") { saved = true }.accessibilityIdentifier("save")
                Text(saved ? "Saved" : "Draft").accessibilityIdentifier(saved ? "saved" : "draft")
                Button("First") {}.accessibilityIdentifier("duplicate")
                Button("Second") {}.accessibilityIdentifier("duplicate")
            }
        }
    }
}
