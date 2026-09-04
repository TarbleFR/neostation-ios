import MetalKit
import UIKit

final class DolphinEmulationViewController: UIViewController {
    let metalView: MTKView
    var onUserClose: (() -> Void)?
    var onCoreEnded: (() -> Void)?

    private let statusLabel = UILabel()
    private var monitorTimer: Timer?
    private var ending = false

    init(device: MTLDevice) {
        metalView = MTKView(frame: .zero, device: device)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.preferredFramesPerSecond = 120
        metalView.framebufferOnly = false
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        view.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        closeButton.layer.cornerRadius = 20
        closeButton.accessibilityLabel = "Stop Dolphin and return to NeoStation"
        closeButton.addTarget(self, action: #selector(closePressed), for: .touchUpInside)
        view.addSubview(closeButton)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Preparing Dolphin JIT…"
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.layer.cornerRadius = 12
        statusLabel.clipsToBounds = true
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -12
            ),
            closeButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 10
            ),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.72),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        monitorTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }

    func setPreparationStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusLabel.text = text
            statusLabel.isHidden = false
        }
    }

    func markRunning() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusLabel.isHidden = true
            beginMonitoringCore()
        }
    }

    func showFailure(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusLabel.text = text
            statusLabel.isHidden = false
        }
    }

    private func beginMonitoringCore() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) {
            [weak self] _ in
            guard let self, !ending else { return }
            if !DolphinNativeRuntime.shared.isRunning {
                ending = true
                monitorTimer?.invalidate()
                onCoreEnded?()
                dismiss(animated: true)
            }
        }
    }

    @objc private func closePressed() {
        guard !ending else { return }
        ending = true
        monitorTimer?.invalidate()
        DolphinNativeRuntime.shared.stop()
        onUserClose?()
        dismiss(animated: true)
    }

    @objc private func applicationWillResignActive() {
        DolphinNativeRuntime.shared.setPaused(true)
    }

    @objc private func applicationDidBecomeActive() {
        DolphinNativeRuntime.shared.setPaused(false)
    }
}
