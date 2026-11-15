import UIKit

// A disposable target for debugger and coordinate checks, never a product preview.
final class FixtureDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        fixtureDiagnostic("application.didFinishLaunching")
        return true
    }
}

@objc(FixtureSceneDelegate)
final class FixtureSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else {
            fixtureDiagnostic("scene.rejected.nonWindowScene")
            return
        }
        fixtureDiagnostic("scene.willConnect")
        let window = UIWindow(windowScene: scene)
        window.rootViewController = FixtureController()
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        fixtureDiagnostic("scene.didBecomeActive")
    }
}

final class FixtureController: UIViewController {
    private var observed: [UIView] = []
    private weak var editTarget: FixtureEditTarget?
    private let editOracle = FixtureEditOracle()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        view.accessibilityIdentifier = "fixture.root"
        observed.append(view)

        let container = add(UIView(frame: CGRect(x: 24, y: 100, width: 260, height: 180)), to: view, id: "fixture.container")
        container.backgroundColor = .systemBlue
        container.clipsToBounds = true
        let transformed = add(UIView(frame: CGRect(x: 35, y: 30, width: 120, height: 65)), to: container, id: "fixture.transform")
        transformed.backgroundColor = .systemOrange
        transformed.transform = CGAffineTransform(rotationAngle: .pi / 6).scaledBy(x: 1.1, y: 0.8)
        let clipped = add(UIView(frame: CGRect(x: 210, y: 130, width: 90, height: 80)), to: container, id: "fixture.clipped")
        clipped.backgroundColor = .systemRed
        let hidden = add(UIView(frame: CGRect(x: 10, y: 10, width: 40, height: 40)), to: container, id: "fixture.hidden")
        hidden.isHidden = true
        let scroll = UIScrollView(frame: CGRect(x: 24, y: 320, width: 260, height: 150))
        scroll.backgroundColor = .systemGray5
        scroll.contentSize = CGSize(width: 500, height: 400)
        _ = add(scroll, to: view, id: "fixture.scroll")
        let scrolled = add(UIView(frame: CGRect(x: 100, y: 125, width: 100, height: 70)), to: scroll, id: "fixture.scrolled")
        scrolled.backgroundColor = .systemGreen
        scroll.contentOffset = CGPoint(x: 40, y: 70)
        // Deliberately excluded from the seven-node geometry oracle.
        let editTarget = makeFixtureEditTarget(frame: CGRect(x: 24, y: 510, width: 260, height: 70))
        view.addSubview(editTarget)
        self.editTarget = editTarget
    }

    private func add(_ child: UIView, to parent: UIView, id: String) -> UIView {
        child.accessibilityIdentifier = id
        parent.addSubview(child)
        observed.append(child)
        return child
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fixtureDiagnostic("view.didAppear")
        writeOracle()
        if let editTarget { editOracle.start(editTarget) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.window != nil { writeOracle() }
    }

    private func writeOracle() {
        guard let window = view.window else { fixtureDiagnostic("oracle.waitingForWindow"); return }
        let screen = window.screen
        let entries: [[String: Any]] = observed.map { item in
            let b = item.bounds
            let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                           CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
            let points = corners.map { item.convert($0, to: screen.fixedCoordinateSpace) }
            return ["id": item.accessibilityIdentifier ?? "", "corners": points.map { [$0.x, $0.y] },
                    "hidden": item.isHidden, "clipsToBounds": item.clipsToBounds,
                    "parentID": item.superview?.accessibilityIdentifier as Any? ?? NSNull()]
        }
        let oracle: [String: Any] = ["capturedAt": ISO8601DateFormatter().string(from: Date()),
                                    "screenScale": screen.scale,
                                    "screenBounds": [screen.bounds.origin.x, screen.bounds.origin.y, screen.bounds.width, screen.bounds.height],
                                    "orientation": window.windowScene?.interfaceOrientation.rawValue as Any? ?? NSNull(),
                                    "coordinateSpace": "UIScreen.fixedCoordinateSpace points", "views": entries]
        do {
            let data = try JSONSerialization.data(withJSONObject: oracle, options: [.prettyPrinted, .sortedKeys])
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try data.write(to: directory.appendingPathComponent("geometry-oracle.json"), options: .atomic)
            fixtureDiagnostic("oracle.written views=\(entries.count) orientation=\(window.windowScene?.interfaceOrientation.rawValue ?? 0)")
        } catch { fixtureDiagnostic("oracle.writeFailed \(error)") }
    }
}
