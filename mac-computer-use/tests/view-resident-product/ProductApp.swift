import UIKit

// An ordinary UIKit app with independent test observations. No mac-cu SDK, helper
// linkage, registration, capture endpoint or product callback exists in this app.
@objc(ResidentProductDelegate)
final class ProductDelegate: UIResponder, UIApplicationDelegate {}

@objc(ResidentProductScene)
final class ProductScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ProductController()
        self.window = window
        window.makeKeyAndVisible()
    }
}

final class ProductController: UIViewController {
    private let oracle = FixtureEditOracle()
    private weak var observed: FixtureEditTarget?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1)
        view.accessibilityIdentifier = "fixture.root"
        let title = UILabel(frame: CGRect(x: 28, y: 105, width: 340, height: 50))
        title.text = "Resident Notes"; title.textColor = .white; title.font = .boldSystemFont(ofSize: 30)
        view.addSubview(title)
        let subtitle = UILabel(frame: CGRect(x: 28, y: 164, width: 340, height: 32))
        subtitle.text = "Current application · UIKit"; subtitle.textColor = .lightGray
        view.addSubview(subtitle)
        let card = makeFixtureEditTarget(frame: CGRect(x: 28, y: 240, width: 300, height: 160))
        card.backgroundColor = UIColor(red: 0.1, green: 0.65, blue: 0.62, alpha: 1)
        card.layer.cornerRadius = 18
        view.addSubview(card); observed = card
        let label = UILabel(frame: CGRect(x: 20, y: 30, width: 260, height: 60))
        label.text = "A live view\nHidden and alpha inspection"; label.numberOfLines = 2
        label.textColor = .white; label.font = .systemFont(ofSize: 19, weight: .medium); card.addSubview(label)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let observed { oracle.start(observed) }
        let data = try! JSONSerialization.data(withJSONObject: ["ready": true])
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! data.write(to: documents.appendingPathComponent("geometry-oracle.json"), options: .atomic)
    }
}

func fixtureDiagnostic(_ message: String) { NSLog("Product observation: %@", message) }
