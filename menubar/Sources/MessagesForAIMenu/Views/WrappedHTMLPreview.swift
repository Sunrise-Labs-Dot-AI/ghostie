import AppKit
import SwiftUI
import WebKit

struct WrappedHTMLPreview: NSViewRepresentable {
  let experience: WrappedGeneratedExperience
  var exportController = WrappedPreviewExportController()
  var previewController: WrappedPreviewController?
  var onTelemetry: (WrappedPreviewTelemetryAction) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let nativePreviewScript = WKUserScript(
      source: "window.__MESSAGES_FOR_AI_NATIVE_PREVIEW = true;",
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    )
    configuration.userContentController.addUserScript(nativePreviewScript)
    configuration.userContentController.add(context.coordinator, name: Coordinator.messageHandlerName)

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true
    webView.setValue(false, forKey: "drawsBackground")
    context.coordinator.webView = webView
    previewController?.register(webView: webView)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.webView = webView
    previewController?.register(webView: webView)
    guard context.coordinator.currentURL != experience.url else { return }
    context.coordinator.currentURL = experience.url
    webView.loadFileURL(experience.url, allowingReadAccessTo: experience.readAccessDirectory)
    context.coordinator.scheduleFocus(for: experience.url, in: webView)
  }

  // The webview must FILL whatever the pane proposes — never answer with the
  // page's own content height. WKWebView's fitting size reports the loaded
  // story's full height (~1800pt), and under the main window's
  // .windowResizability(.contentSize) that ideal balloons the entire window
  // layout past the screen: the sidebar and toolbar lay out thousands of
  // points tall and the visible window shows an empty middle slice (P0).
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageHandlerName)
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let messageHandlerName = "messagesForAIWrapped"

    var parent: WrappedHTMLPreview
    var currentURL: URL?
    weak var webView: WKWebView?
    private var pendingFocusURL: URL?
    private var focusAttempt = 0

    init(parent: WrappedHTMLPreview) {
      self.parent = parent
    }

    func scheduleFocus(for url: URL, in webView: WKWebView) {
      pendingFocusURL = url
      focusAttempt = 0
      requestFocus(in: webView)
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.targetFrame?.isMainFrame == false {
        decisionHandler(.allow)
        return
      }

      let policy = WrappedPreviewNavigationPolicy(readAccessDirectory: parent.experience.readAccessDirectory)
      switch policy.decision(for: navigationAction.request.url) {
      case .allowInPreview:
        decisionHandler(.allow)
      case .openExternally(let url):
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
      case .cancel:
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      requestFocus(in: webView)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      if let payload = try? WrappedPreviewFilePayload(messageBody: message.body) {
        handleFilePayload(payload)
        return
      }
      if let payload = message.body as? [String: Any],
         let rawAction = payload["action"] as? String,
         WrappedPreviewFileAction(rawValue: rawAction) != nil {
        completeNativeRequest(requestID: payload["requestId"] as? String, ok: false, error: "invalid_payload")
        return
      }

      let rawAction: String?
      if let action = message.body as? String {
        rawAction = action
      } else if let payload = message.body as? [String: Any] {
        rawAction = payload["action"] as? String
      } else {
        rawAction = nil
      }

      guard let rawAction,
            let action = WrappedPreviewTelemetryAction(rawValue: rawAction)
      else { return }
      parent.onTelemetry(action)
    }

    private func handleFilePayload(_ payload: WrappedPreviewFilePayload) {
      guard let webView else {
        completeFilePayload(payload, ok: false, error: "missing_webview")
        return
      }

      do {
        try parent.exportController.handle(payload, presentingFrom: webView)
        if payload.action == .shareCard {
          parent.onTelemetry(.share)
        } else if payload.action == .shareAll {
          parent.onTelemetry(.shareAll)
        }
        completeFilePayload(payload, ok: true, error: nil)
      } catch {
        completeFilePayload(payload, ok: false, error: String(describing: error))
      }
    }

    private func completeFilePayload(_ payload: WrappedPreviewFilePayload, ok: Bool, error: String?) {
      completeNativeRequest(requestID: payload.requestID, ok: ok, error: error)
    }

    private func completeNativeRequest(requestID: String?, ok: Bool, error: String?) {
      guard let requestID, let webView else { return }
      var body: [String: Any] = [
        "requestId": requestID,
        "ok": ok
      ]
      if let error {
        body["error"] = error
      }
      guard let data = try? JSONSerialization.data(withJSONObject: body),
            let json = String(data: data, encoding: .utf8)
      else { return }
      webView.evaluateJavaScript("window.__messagesForAIWrappedNativeResult?.(\(json));")
    }

    private func requestFocus(in webView: WKWebView) {
      DispatchQueue.main.async { [weak self, weak webView] in
        self?.attemptFocus(in: webView)
      }
    }

    private func attemptFocus(in webView: WKWebView?) {
      guard let webView,
            let pendingFocusURL,
            currentURL == pendingFocusURL
      else { return }

      if let window = webView.window, window.makeFirstResponder(webView) {
        self.pendingFocusURL = nil
        focusAttempt = 0
        return
      }

      guard WrappedPreviewFocusPolicy.shouldRetry(afterAttempt: focusAttempt) else { return }
      focusAttempt += 1
      DispatchQueue.main.asyncAfter(deadline: .now() + WrappedPreviewFocusPolicy.retryDelay) { [weak self, weak webView] in
        self?.attemptFocus(in: webView)
      }
    }
  }
}

enum WrappedPreviewFocusPolicy {
  static let maxAttempts = 8
  static let retryDelay: DispatchTimeInterval = .milliseconds(60)

  static func shouldRetry(afterAttempt attempt: Int) -> Bool {
    attempt < maxAttempts
  }
}
