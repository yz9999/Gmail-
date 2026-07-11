import SwiftUI
import UIKit
import WebKit

struct HTMLWebView: UIViewRepresentable {
    let html: String
    var contentScale: Double = 0.90

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = true
        view.scrollView.alwaysBounceHorizontal = false
        view.scrollView.showsHorizontalScrollIndicator = false
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // WKWebView.pageZoom 会等比缩放邮件原始排版，避免只改字号导致 HTML 邮件错位。
        webView.pageZoom = CGFloat(min(max(contentScale, 0.75), 1.15))
        let wrapped = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline' https:; font-src data: https:">
        <style>
        *{box-sizing:border-box}
        html,body{margin:0;padding:0;width:100%;max-width:100%;background:transparent;color:#202124;font:16px -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;line-height:1.5;overflow-x:hidden;overflow-wrap:anywhere;-webkit-text-size-adjust:100%}
        table{max-width:100%!important}
        td,th,div,p,span{overflow-wrap:anywhere;word-break:break-word}
        img,video,iframe,object{max-width:100%!important;height:auto!important}
        pre{max-width:100%;white-space:pre-wrap;overflow-x:auto}
        blockquote{margin-left:10px;margin-right:0;padding-left:10px;border-left:3px solid #dadce0}
        @media(prefers-color-scheme:dark){html,body{color:#e8eaed}a{color:#8ab4f8}blockquote{border-left-color:#5f6368}}
        </style>
        </head><body>\(html)</body></html>
        """
        if context.coordinator.lastHTML != wrapped {
            context.coordinator.lastHTML = wrapped
            webView.loadHTMLString(wrapped, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
