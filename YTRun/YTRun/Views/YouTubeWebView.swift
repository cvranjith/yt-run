//
//  YouTubeWebView.swift
//  YTRun
//

import SwiftUI
@preconcurrency import WebKit

// SwiftUI has no native web view, so we bridge UIKit's WKWebView via
// `UIViewRepresentable`. Unlike a typical representable, this one doesn't
// own or configure the web view itself — it just displays whatever
// `WKWebView` the long-lived `YouTubeWebViewStore` already has, so
// leaving and returning to this screen shows the exact same page/session
// instead of starting over. See `YouTubeWebViewStore` for the setup.
struct YouTubeWebView: UIViewRepresentable {
    let store: YouTubeWebViewStore

    func makeUIView(context: Context) -> WKWebView {
        store.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // No-op: the store is the single source of truth for what's
        // loaded. Callers ask the store to `load(_:)` a new URL directly.
    }
}
