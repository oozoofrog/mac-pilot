import UIKit

final class FixtureDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        fixtureDiagnostic("application.didFinishLaunching")
        return true
    }
}

@objc(FixtureSceneDelegate)
final class FixtureSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = FixtureController()
        self.window = window
        window.makeKeyAndVisible()
        fixtureDiagnostic("scene.willConnect")
    }
}

final class FixtureController: UIViewController, UITextFieldDelegate {
    private var counters: [String: Int] = [:]
    private var generation = 0
    private var recreated: UIButton?
    private var secureField: UITextField!
    private var textField: UITextField!
    private var adjustable: AdjustableElement!
    private var oracleTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        button("Press", "press", y: 80, action: #selector(press))
        let disabled = button("Disabled", "disabled", y: 125, action: #selector(disabledPress))
        disabled.isEnabled = false
        button("Recreate", "recreate", y: 170, action: #selector(recreate))
        installRecreated()
        textField = UITextField(frame: CGRect(x: 20, y: 265, width: 280, height: 36))
        textField.borderStyle = .roundedRect
        textField.accessibilityIdentifier = "fixture.text"
        textField.text = "initial"
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        view.addSubview(textField)
        let secure = UITextField(frame: CGRect(x: 20, y: 310, width: 280, height: 36))
        secure.borderStyle = .roundedRect
        secureField = secure
        secure.isSecureTextEntry = true
        secure.text = "fixture-secret"
        secure.accessibilityIdentifier = "fixture.secure"
        view.addSubview(secure)
        let covered = button("Covered", "covered", y: 355, action: #selector(coveredPress))
        let cover = UIView(frame: covered.frame)
        cover.backgroundColor = .gray
        cover.isAccessibilityElement = false
        view.addSubview(cover)
        let custom = button("Custom", "custom", y: 400, action: #selector(press))
        custom.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Duplicate", target: self, selector: #selector(customA)),
            UIAccessibilityCustomAction(name: "Duplicate", target: self, selector: #selector(customB))
        ]
        adjustable = AdjustableElement(accessibilityContainer: view!)
        adjustable.owner = self
        adjustable.accessibilityLabel = "Adjustable"
        adjustable.accessibilityIdentifier = "fixture.adjustable"
        adjustable.accessibilityTraits = .adjustable
        adjustable.accessibilityFrameInContainerSpace = CGRect(x: 20, y: 445, width: 280, height: 36)
        view.accessibilityElements = (view.subviews.filter { $0 !== cover } as [Any]) + [adjustable as Any]
        writeOracle()
        // Sample the actual property independently of editingChanged/AX notifications.
        oracleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let command = dir.appendingPathComponent("recreate.request")
            if FileManager.default.fileExists(atPath: command.path) {
                try? FileManager.default.removeItem(at: command)
                self.recreate()
            }
            self.writeOracle()
        }
    }
    @discardableResult private func button(_ label: String, _ id: String, y: CGFloat, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.frame = CGRect(x: 20, y: y, width: 280, height: 36)
        b.setTitle(label, for: .normal)
        b.accessibilityIdentifier = "fixture.\(id)"
        b.addTarget(self, action: action, for: .touchUpInside)
        view.addSubview(b)
        return b
    }
    private func installRecreated() {
        recreated = button("Recreated", "recreated", y: 215, action: #selector(recreatedPress))
    }
    @objc private func recreate() {
        count("recreate")
        recreated?.removeFromSuperview()
        generation += 1
        installRecreated()
        view.accessibilityElements = (view.subviews as [Any]) + [adjustable as Any]
        writeOracle()
    }
    @objc private func press() { count("press") }
    @objc private func disabledPress() { count("disabled") }
    @objc private func coveredPress() { count("covered") }
    @objc private func recreatedPress() { count("recreated") }
    @objc private func customA() -> Bool { count("customA"); return true }
    @objc private func customB() -> Bool { count("customB"); return true }
    @objc private func textChanged() { count("textChanged") }
    func count(_ name: String) { counters[name, default: 0] += 1; writeOracle() }
    private func writeOracle() {
        let model: [String: Any] = ["secureUnchanged": secureField?.text == "fixture-secret", "generation": generation, "counters": counters, "text": textField?.text ?? "", "adjustment": adjustable?.value ?? 0]
        do {
            let data = try JSONSerialization.data(withJSONObject: model, options: [.sortedKeys])
            let dir = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try data.write(to: dir.appendingPathComponent("ax-oracle.json"), options: .atomic)
        } catch { fixtureDiagnostic("oracle.writeFailed") }
    }
}

final class AdjustableElement: UIAccessibilityElement {
    weak var owner: FixtureController?
    var value = 0
    override var accessibilityValue: String? { get { String(value) } set {} }
    override func accessibilityIncrement() { value += 1; owner?.count("increment") }
    override func accessibilityDecrement() { value -= 1; owner?.count("decrement") }
}
