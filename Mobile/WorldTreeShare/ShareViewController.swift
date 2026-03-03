import UIKit
import Social
import MobileCoreServices
import UniformTypeIdentifiers

// MARK: - App Group + URL Scheme constants
// These must match the values in the main app target.
private enum ShareConstants {
    static let appGroupID = "group.com.evanprimeau.worldtree"
    static let pendingShareTextKey = "pendingShareText"
    static let pendingShareURLKey = "pendingShareURL"
    static let urlScheme = "worldtree"
}

final class ShareViewController: UIViewController {

    // MARK: - State

    private var sharedText: String?
    private var sharedURL: String?

    // MARK: - UI

    private let containerView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.systemBackground
        v.layer.cornerRadius = 16
        v.layer.masksToBounds = true
        return v
    }()

    private let handleView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.systemFill
        v.layer.cornerRadius = 2.5
        return v
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = "Branch in World Tree"
        l.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        l.textAlignment = .center
        return l
    }()

    private let previewLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.numberOfLines = 6
        l.font = UIFont.systemFont(ofSize: 14)
        l.textColor = UIColor.secondaryLabel
        l.textAlignment = .left
        return l
    }()

    private let previewContainer: UIScrollView = {
        let s = UIScrollView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.backgroundColor = UIColor.secondarySystemBackground
        s.layer.cornerRadius = 10
        return s
    }()

    private let branchButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Create Branch"
        config.image = UIImage(systemName: "arrow.triangle.branch")
        config.imagePadding = 8
        config.cornerStyle = .large
        config.baseBackgroundColor = UIColor.systemIndigo
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let cancelButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = "Cancel"
        config.baseForegroundColor = UIColor.systemGray
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        buildUI()
        extractSharedContent()
    }

    // MARK: - UI Construction

    private func buildUI() {
        view.addSubview(containerView)
        containerView.addSubview(handleView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(previewContainer)
        previewContainer.addSubview(previewLabel)
        containerView.addSubview(branchButton)
        containerView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            // Container — bottom sheet style
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Handle pill
            handleView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            handleView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            handleView.widthAnchor.constraint(equalToConstant: 36),
            handleView.heightAnchor.constraint(equalToConstant: 5),

            // Title
            titleLabel.topAnchor.constraint(equalTo: handleView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // Preview scroll container
            previewContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            previewContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            previewContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            previewContainer.heightAnchor.constraint(equalToConstant: 120),

            // Preview label inside scroll view
            previewLabel.topAnchor.constraint(equalTo: previewContainer.contentLayoutGuide.topAnchor, constant: 10),
            previewLabel.leadingAnchor.constraint(equalTo: previewContainer.contentLayoutGuide.leadingAnchor, constant: 12),
            previewLabel.trailingAnchor.constraint(equalTo: previewContainer.contentLayoutGuide.trailingAnchor, constant: -12),
            previewLabel.bottomAnchor.constraint(equalTo: previewContainer.contentLayoutGuide.bottomAnchor, constant: -10),
            previewLabel.widthAnchor.constraint(equalTo: previewContainer.frameLayoutGuide.widthAnchor, constant: -24),

            // Branch button
            branchButton.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 20),
            branchButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            branchButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            branchButton.heightAnchor.constraint(equalToConstant: 50),

            // Cancel button
            cancelButton.topAnchor.constraint(equalTo: branchButton.bottomAnchor, constant: 4),
            cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        branchButton.addTarget(self, action: #selector(didTapBranch), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
    }

    // MARK: - Content Extraction

    private func extractSharedContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            updatePreview(text: nil, url: nil)
            return
        }

        let group = DispatchGroup()
        var extractedText: String?
        var extractedURL: String?

        for item in items {
            for provider in item.attachments ?? [] {

                // Plain text
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                        defer { group.leave() }
                        if let text = data as? String, extractedText == nil {
                            extractedText = text
                        }
                    }
                }

                // URL — extract the URL string; may also carry page title via NSExtensionItem.attributedContentText
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { data, _ in
                        defer { group.leave() }
                        if let url = data as? URL, extractedURL == nil {
                            extractedURL = url.absoluteString
                            // Use URL as text fallback if no plain text present
                            if extractedText == nil {
                                extractedText = url.absoluteString
                            }
                        }
                    }
                }

                // Rich / attributed text (e.g. selected text in Safari)
                if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.rtf.identifier, options: nil) { data, _ in
                        defer { group.leave() }
                        if let attributed = data as? NSAttributedString, extractedText == nil {
                            extractedText = attributed.string
                        } else if let rtfData = data as? Data,
                                  let attributed = try? NSAttributedString(
                                    data: rtfData,
                                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                                    documentAttributes: nil
                                  ), extractedText == nil {
                            extractedText = attributed.string
                        }
                    }
                }
            }

            // Attributed content text from the item itself (Safari page title + URL)
            if let attributed = item.attributedContentText, extractedText == nil {
                group.enter()
                DispatchQueue.main.async {
                    defer { group.leave() }
                    extractedText = attributed.string
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.sharedText = extractedText
            self?.sharedURL = extractedURL
            self?.updatePreview(text: extractedText, url: extractedURL)
        }
    }

    private func updatePreview(text: String?, url: String?) {
        let displayText: String
        if let text, !text.isEmpty {
            displayText = text
        } else if let url, !url.isEmpty {
            displayText = url
        } else {
            displayText = "(No text selected)"
        }
        previewLabel.text = displayText
        branchButton.isEnabled = text != nil || url != nil
    }

    // MARK: - Actions

    @objc private func didTapBranch() {
        guard let text = sharedText, !text.isEmpty else {
            didTapCancel()
            return
        }

        // 1. Write to App Group UserDefaults so the main app can read it on launch.
        if let suite = UserDefaults(suiteName: ShareConstants.appGroupID) {
            suite.set(text, forKey: ShareConstants.pendingShareTextKey)
            if let url = sharedURL {
                suite.set(url, forKey: ShareConstants.pendingShareURLKey)
            } else {
                suite.removeObject(forKey: ShareConstants.pendingShareURLKey)
            }
            suite.synchronize()
        }

        // 2. Build the URL scheme deep-link.
        //    We always write to App Group first so the app can reconstruct full text
        //    even if it exceeds what fits in a URL query parameter.
        var components = URLComponents()
        components.scheme = ShareConstants.urlScheme
        components.host = "newbranch"

        // Truncate to 1500 chars so the URL stays well within OS limits.
        // Full text is available in App Group storage regardless.
        let preview = String(text.prefix(1500))
        components.queryItems = [
            URLQueryItem(name: "text", value: preview),
        ]
        if let urlStr = sharedURL {
            components.queryItems?.append(URLQueryItem(name: "sourceURL", value: urlStr))
        }

        guard let appURL = components.url else {
            completeRequest()
            return
        }

        // 3. Open the main app. extensionContext?.open(_:completionHandler:) is the correct
        //    API for Share Extensions on iOS 17+.
        extensionContext?.open(appURL, completionHandler: { [weak self] success in
            self?.completeRequest()
        })
    }

    @objc private func didTapCancel() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: "com.evanprimeau.world-tree-mobile.share",
            code: NSUserCancelledError,
            userInfo: nil
        ))
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
