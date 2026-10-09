import UIKit

/// Your server's two addresses: one for home Wi-Fi, one for away (Tailscale).
/// Usually already filled in — they're built into the app and the server tells the app the rest — so this
/// screen is mostly for changing them (Settings → Change addresses).
final class SetupViewController: UIViewController, UITextFieldDelegate {

    private let field = UITextField()      // home
    private let awayField = UITextField()  // away
    private let hadServer = Prefs.server != nil
    private let connect = UIButton.marquee("Connect", primary: true)
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .mqBackground

        let logo = UIImageView(image: UIImage(named: "Logo"))
        logo.contentMode = .scaleAspectFit
        logo.widthAnchor.constraint(equalToConstant: 72).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let title = label(hadServer ? "Your server's addresses" : "Welcome to Marquee", size: 28, weight: .bold, color: .mqText)
        let intro = label("Marquee uses the home address when you're on your Wi-Fi and the away address everywhere else. It chooses by itself — you never have to pick.",
                          size: 16, weight: .regular, color: .mqMuted)

        style(field, placeholder: "192.168.80.35:8420", next: true)
        field.text = Addresses.home
        style(awayField, placeholder: "zimaos.tail1234.ts.net  (optional)", next: false)
        awayField.text = Addresses.away
        let homeLabel = label("AT HOME (YOUR WI-FI)", size: 12, weight: .semibold, color: .mqMuted)
        let awayLabel = label("AWAY FROM HOME (TAILSCALE)", size: 12, weight: .semibold, color: .mqMuted)

        connect.addTarget(self, action: #selector(tryConnect), for: .touchUpInside)

        status.numberOfLines = 0
        status.font = .systemFont(ofSize: 15)
        status.textColor = .mqMuted
        status.isHidden = true
        spinner.color = .mqAccent
        spinner.hidesWhenStopped = true

        let help = label("""
        Home: your ZimaOS box's address on your Wi-Fi, like 192.168.80.35:8420.

        Away: the box's Tailscale address, like zimaos.tail1234.ts.net or 100.x.y.z:8420. Leave it empty if you don't know it — once it's saved in Marquee → Settings → Server addresses on any device, this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") picks it up by itself.

        Tip: in the Tailscale app, tap your picture → VPN On Demand, and Tailscale switches itself on whenever you leave your Wi-Fi.
        """, size: 14, weight: .regular, color: .mqMuted)

        // keep the logo at its own size, left aligned
        let logoRow = UIStackView(arrangedSubviews: [logo, UIView()])
        let stack = UIStackView(arrangedSubviews: [logoRow, title, intro, homeLabel, field, awayLabel, awayField, connect, spinner, status, help])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.setCustomSpacing(24, after: intro)
        stack.setCustomSpacing(6, after: homeLabel)
        stack.setCustomSpacing(6, after: awayLabel)
        stack.setCustomSpacing(28, after: status)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        let readable = view.readableContentGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: readable.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: readable.trailingAnchor, constant: -4),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])

        // Opened from inside Marquee → offer a way back, and to the downloads
        if hadServer {
            let close = UIButton(type: .close)
            close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
            close.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(close)
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
                close.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            ])
        }
        if !DownloadStore.shared.items.isEmpty {
            let downloads = UIButton.marquee("Watch your downloads", primary: false)
            downloads.addTarget(self, action: #selector(openDownloads), for: .touchUpInside)
            stack.insertArrangedSubview(downloads, at: stack.arrangedSubviews.firstIndex(of: spinner) ?? 5)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hadServer { field.becomeFirstResponder() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = text
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func style(_ f: UITextField, placeholder: String, next: Bool) {
        f.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.mqMuted.withAlphaComponent(0.6)])
        f.textColor = .mqText
        f.font = .systemFont(ofSize: 18)
        f.keyboardType = .URL
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.spellCheckingType = .no
        f.textContentType = .URL
        f.returnKeyType = next ? .next : .go
        f.clearButtonMode = .whileEditing
        f.delegate = self
        f.backgroundColor = .mqPanel
        f.layer.cornerRadius = 12
        f.layer.borderWidth = 1
        f.layer.borderColor = UIColor.mqPanel2.cgColor
        f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        f.leftViewMode = .always
        f.heightAnchor.constraint(equalToConstant: 52).isActive = true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === field { awayField.becomeFirstResponder() } else { tryConnect() }
        return true
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func openDownloads() {
        let nav = UINavigationController(rootViewController: DownloadsViewController())
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    @objc private func tryConnect() {
        let home = Prefs.normalise(field.text ?? "")
        let away = Prefs.normalise(awayField.text ?? "")
        guard !home.isEmpty || !away.isEmpty else {
            status.text = "Type at least one address."
            status.isHidden = false
            return
        }
        view.endEditing(true)
        connect.isEnabled = false
        spinner.startAnimating()
        status.isHidden = true

        Task { @MainActor [weak self] in
            // Either address answering is enough — you might be setting this up away from home.
            // (Patient: a server busy scanning a big library can take a while to answer.)
            let found = await Servers.race(home: home.isEmpty ? nil : home, away: away.isEmpty ? nil : away, homeWait: 12, awayWait: 12)
            let working = found?.0
            self?.finish(home: home.isEmpty ? nil : home, away: away.isEmpty ? nil : away, working: working)
        }
    }

    private func finish(home: String?, away: String?, working: String?) {
        connect.isEnabled = true
        spinner.stopAnimating()
        guard let working = working else {
            status.text = "Neither address answered. Check them, and that Tailscale is on if you're away from home. If iOS asked about \"devices on your local network\", choose Allow (Settings → Marquee → Local Network)."
            status.isHidden = false
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        // A server this app has never talked to: its notifications and widget key start afresh
        if !Addresses.candidates.contains(working) {
            Prefs.lastNoteId = 0
            SharedStore.deviceKey = nil
        }
        Addresses.set(home: home, away: away)
        Prefs.server = working
        Prefs.publish()
        let scene = view.window?.windowScene?.delegate as? SceneDelegate
        if presentingViewController != nil {
            dismiss(animated: true) { scene?.showMain() } // connect afresh with the addresses just saved
        } else {
            scene?.showMain()
        }
    }
}
