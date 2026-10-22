import SwiftUI
import WebKit

/// Zeigt KI-Antworten mit schön gesetzten Formeln (KaTeX). Ohne Internet: einfache Darstellung.
struct MathMarkdownView: View {
    let text: String
    @State private var height: CGFloat = 60
    @State private var failed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if failed {
            MarkdownText(text: text)
                .textSelection(.enabled)
        } else {
            MathWebView(text: text, dark: colorScheme == .dark, height: $height, failed: $failed)
                .frame(height: height)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Feste Versionen der Bibliotheken, damit sich die Darstellung nicht unerwartet ändert.
enum MathAssets {
    static let katex = "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/"
    static let marked = "https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"

    static func html(dark: Bool) -> String {
        let fg = dark ? "#ECEDF5" : "#16182B"
        let codeBG = dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.05)"
        return """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <link rel="stylesheet" href="\(katex)katex.min.css">
        <script src="\(katex)katex.min.js"></script>
        <script src="\(katex)contrib/auto-render.min.js"></script>
        <script src="\(marked)"></script>
        <style>
          html, body { margin: 0; padding: 0; background: transparent; }
          body { font: -apple-system-body; font-size: 17px; line-height: 1.5; color: \(fg);
                 -webkit-text-size-adjust: none; overflow: hidden; word-wrap: break-word; }
          #c > :first-child { margin-top: 0; } #c > :last-child { margin-bottom: 0; }
          h1, h2, h3, h4 { font-size: 1.05em; margin: 0.8em 0 0.3em; }
          h1 { font-size: 1.2em; }
          p { margin: 0 0 0.55em; }
          ul, ol { margin: 0 0 0.55em; padding-left: 1.3em; }
          li { margin: 0.15em 0; }
          code { font: 0.9em ui-monospace, Menlo, monospace; background: \(codeBG); padding: 1px 5px; border-radius: 5px; }
          pre { background: \(codeBG); padding: 10px; border-radius: 10px; overflow-x: auto; }
          pre code { background: none; padding: 0; }
          .katex-display { margin: 0.6em 0; overflow-x: auto; overflow-y: hidden; padding: 2px 0; }
          .katex { font-size: 1.08em; }
          table { border-collapse: collapse; } td, th { border: 1px solid \(codeBG); padding: 4px 8px; }
        </style></head><body><div id="c"></div>
        <script>
          function post(name, value) {
            try { window.webkit.messageHandlers[name].postMessage(value); } catch (e) {}
          }
          function report() { post("height", Math.ceil(document.getElementById("c").getBoundingClientRect().height)); }
          // Formeln vor Markdown schützen, sonst werden _ und * darin umgedeutet.
          function render(md) {
            var math = [];
            var src = md.replace(/\\$\\$[\\s\\S]+?\\$\\$|\\\\\\[[\\s\\S]+?\\\\\\]|\\\\\\([\\s\\S]+?\\\\\\)|\\$[^$\\n]+?\\$/g, function (m) {
              math.push(m); return "@@MATH" + (math.length - 1) + "@@";
            });
            var html = marked.parse(src, { breaks: true });
            html = html.replace(/@@MATH(\\d+)@@/g, function (_, i) {
              return math[+i].replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
            });
            var c = document.getElementById("c");
            c.innerHTML = html;
            renderMathInElement(c, {
              delimiters: [
                { left: "$$", right: "$$", display: true },
                { left: "\\\\[", right: "\\\\]", display: true },
                { left: "\\\\(", right: "\\\\)", display: false },
                { left: "$", right: "$", display: false }
              ],
              throwOnError: false
            });
            report();
          }
          window.addEventListener("load", function () {
            if (window.marked && window.renderMathInElement) {
              new ResizeObserver(report).observe(document.getElementById("c"));
              post("ready", true);
            } else {
              post("failed", true);
            }
          });
        </script></body></html>
        """
    }
}

struct MathWebView: UIViewRepresentable {
    let text: String
    let dark: Bool
    @Binding var height: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        let proxy = WeakMessageHandler(context.coordinator)
        for name in ["height", "ready", "failed"] { controller.add(proxy, name: name) }
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        context.coordinator.dark = dark
        web.loadHTMLString(MathAssets.html(dark: dark), baseURL: URL(string: "https://cdn.jsdelivr.net/"))
        context.coordinator.startTimeout()
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.dark != dark {
            context.coordinator.dark = dark
            context.coordinator.isReady = false
            context.coordinator.rendered = nil
            web.loadHTMLString(MathAssets.html(dark: dark), baseURL: URL(string: "https://cdn.jsdelivr.net/"))
            return
        }
        context.coordinator.renderIfNeeded(in: web)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        for name in ["height", "ready", "failed"] {
            web.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MathWebView
        var dark = false
        var isReady = false
        var rendered: String?
        private weak var webView: WKWebView?

        init(_ parent: MathWebView) { self.parent = parent }

        func startTimeout() {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !self.isReady else { return }
                self.parent.failed = true
            }
        }

        func renderIfNeeded(in web: WKWebView) {
            webView = web
            guard isReady, rendered != parent.text,
                  let data = try? JSONEncoder().encode(parent.text),
                  let json = String(data: data, encoding: .utf8) else { return }
            rendered = parent.text
            web.evaluateJavaScript("render(\(json))", completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "ready":
                isReady = true
                if let web = message.webView { renderIfNeeded(in: web) }
            case "height":
                if let h = message.body as? Double, h > 0, abs(CGFloat(h) - parent.height) > 0.5 {
                    parent.height = CGFloat(h) + 4
                }
            default:
                parent.failed = true
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.failed = true
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.failed = true
        }

        /// Links öffnen im Browser statt in der Antwort.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// Verhindert, dass der Web-View seinen Coordinator festhält.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
