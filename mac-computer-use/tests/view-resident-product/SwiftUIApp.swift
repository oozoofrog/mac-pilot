import SwiftUI

@main
struct ProductSwiftUI: App {
    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "--fixture-session",
              let token = ProcessInfo.processInfo.environment["MAC_CU_FIXTURE_SESSION"], arguments[1] == token,
              getenv("MAC_CU_FIXTURE_CHILD") == nil else { exit(64) }
        setenv("MAC_CU_FIXTURE_CHILD", "1", 1)
    }
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 32) {
                Text("Resident Notes").font(.largeTitle.bold())
                Text("Current application · SwiftUI")
                ObservedCard().frame(width: 300, height: 160)
                Spacer()
            }.padding(28)
        }
    }
}

struct ObservedCard: UIViewRepresentable {
    final class Coordinator { let oracle = FixtureEditOracle() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 160))
        root.accessibilityIdentifier = "fixture.root"
        let card = makeFixtureEditTarget(frame: root.bounds)
        card.backgroundColor = .systemTeal
        root.addSubview(card)
        let oracle = context.coordinator.oracle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            oracle.start(card)
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? Data("{\"ready\":true}".utf8).write(to: documents.appendingPathComponent("geometry-oracle.json"), options: .atomic)
        }
        return root
    }
    func updateUIView(_ view: UIView, context: Context) {}
}
