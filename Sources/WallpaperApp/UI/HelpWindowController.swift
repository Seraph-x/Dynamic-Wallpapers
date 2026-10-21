import AppKit
import WebKit
import WallpaperCore

@MainActor
enum AppHelp {
    private static var controller: HelpWindowController?

    static func open(localizer: AppLocalizer, product: ProductBundleMetadata) {
        do {
            let document = try HelpDocument.bundled(language: localizer.language)
            if controller == nil {
                controller = HelpWindowController(product: product, reportFailure: presentFailure)
            }
            controller?.open(document, localizer: localizer)
        } catch {
            presentFailure(error, localizer)
        }
    }

    static func presentFailure(_ error: Error, _ localizer: AppLocalizer) {
        let message = (error as? WallpaperError)?.message ?? "帮助内容加载失败，请重新打开帮助文档。"
        let details = (error as? WallpaperError)?.diagnostic ?? String(describing: error as NSError)
        NSApplication.shared.activate(ignoringOtherApps: true)
        FailureAlert.present(PresentedFailure(title: "无法打开帮助文档", summary: message, diagnostics: details),
                             localizer: localizer)
    }
}

@MainActor
final class HelpWindowController: NSWindowController, WKNavigationDelegate {
    let webView: WKWebView
    private let product: ProductBundleMetadata
    private var localizer = AppLocalizer()
    private var helpRoot: URL?
    private let reportFailure: @MainActor (Error, AppLocalizer) -> Void

    init(product: ProductBundleMetadata,
         reportFailure: @escaping @MainActor (Error, AppLocalizer) -> Void) {
        self.product = product
        self.reportFailure = reportFailure
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = CGSize(width: 680, height: 480)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = webView
        window.center()
        super.init(window: window)
        webView.navigationDelegate = self
        configuration.userContentController.add(HelpLanguageHandler(owner: self), name: "helpLanguage")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open(_ document: HelpDocument, localizer: AppLocalizer) {
        self.localizer = localizer
        helpRoot = document.root
        window?.title = "\(product.displayName) — \(localizer("帮助文档"))"
        // Always load the app's current language, even if this window last displayed another one.
        webView.loadFileURL(document.url, allowingReadAccessTo: document.root)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let title = webView.title { window?.title = title }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reportFailure(WallpaperError("帮助内容加载失败，请重新打开帮助文档。",
                                    diagnostic: "WebKit help content process terminated"), localizer)
    }

    fileprivate func changeLanguage(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let code = message.body as? String,
              let language = AppLanguage(rawValue: code), language != .system, let helpRoot else {
            reportFailure(WallpaperError("帮助内容加载失败，请重新打开帮助文档。",
                                        diagnostic: "Invalid help language navigation request"), localizer)
            return
        }
        do {
            // Only an AppLanguage is accepted, never a URL or filesystem path from JavaScript.
            let next = try HelpDocument(language: language, root: helpRoot)
            var url = URLComponents(url: next.url, resolvingAgainstBaseURL: false)!
            url.fragment = webView.url?.fragment
            webView.loadFileURL(url.url!, allowingReadAccessTo: next.root)
        } catch {
            reportFailure(error, localizer)
        }
    }

    private func navigationFailed(_ error: Error) {
        let failure = error as NSError
        // Opening help again deliberately cancels an older in-flight navigation.
        guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
        reportFailure(error, localizer)
    }
}

/// WKUserContentController retains handlers. The weak owner avoids retaining the help window forever.
@MainActor
private final class HelpLanguageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: HelpWindowController?

    init(owner: HelpWindowController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.changeLanguage(message)
    }
}
