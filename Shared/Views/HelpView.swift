//
//  HelpView.swift
//  Peel
//
//  Created: January 28, 2026
//  Displays bundled product documentation within the app
//

import SwiftUI
#if os(macOS)
import WebKit
#endif

#if os(macOS)
/// A WebView wrapper for rendering markdown as HTML
struct MarkdownWebView: NSViewRepresentable {
  let markdown: String
  let resourcesURL: URL?
  
  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.preferences.isTextInteractionEnabled = true
    
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    return webView
  }
  
  func updateNSView(_ webView: WKWebView, context: Context) {
    let html = convertMarkdownToHTML(markdown)
    
    // Load with base URL pointing to resources for images
    if let baseURL = resourcesURL {
      webView.loadHTMLString(html, baseURL: baseURL)
    } else {
      webView.loadHTMLString(html, baseURL: nil)
    }
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator()
  }
  
  class Coordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
      // Handle link clicks - open in browser if it's an external link
      if navigationAction.navigationType == .linkActivated,
         let url = navigationAction.request.url {
        if url.scheme == "http" || url.scheme == "https" {
          NSWorkspace.shared.open(url)
          return .cancel
        }
      }
      return .allow
    }
  }
  
  private func convertMarkdownToHTML(_ markdown: String) -> String {
    var html = markdown
    
    // First, resolve image paths to absolute file URLs
    if let resourcesURL = resourcesURL {
      // Replace images with absolute file:// URLs
      let imagePattern = "!\\[([^\\]]*)\\]\\(images/([^)]+)\\)"
      if let regex = try? NSRegularExpression(pattern: imagePattern, options: []) {
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range).reversed()
        
        for match in matches {
          if let filenameRange = Range(match.range(at: 2), in: html),
             let fullRange = Range(match.range, in: html),
             let altRange = Range(match.range(at: 1), in: html) {
            let filename = String(html[filenameRange])
            let alt = String(html[altRange])
            let imageURL = resourcesURL.appendingPathComponent(filename)
            let imgTag = "<img src=\"\(imageURL.absoluteString)\" alt=\"\(alt)\" style=\"max-width:100%; border-radius:8px; margin:16px 0; box-shadow: 0 2px 8px rgba(0,0,0,0.2);\">"
            html.replaceSubrange(fullRange, with: imgTag)
          }
        }
      }
    }
    
    // Convert code blocks first (before other processing)
    let codeBlockPattern = "```(\\w*)\\n([\\s\\S]*?)```"
    if let regex = try? NSRegularExpression(pattern: codeBlockPattern, options: []) {
      let range = NSRange(html.startIndex..., in: html)
      html = regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "<pre><code class=\"$1\">$2</code></pre>")
    }
    
    // Convert inline code
    html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
    
    // Convert headers
    html = html.replacingOccurrences(of: "(?m)^#### (.+)$", with: "<h4>$1</h4>", options: .regularExpression)
    html = html.replacingOccurrences(of: "(?m)^### (.+)$", with: "<h3 id=\"$1\">$1</h3>", options: .regularExpression)
    html = html.replacingOccurrences(of: "(?m)^## (.+)$", with: "<h2 id=\"$1\">$1</h2>", options: .regularExpression)
    html = html.replacingOccurrences(of: "(?m)^# (.+)$", with: "<h1>$1</h1>", options: .regularExpression)
    
    // Convert links (images already handled above)
    html = html.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
    
    // Convert bold
    html = html.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
    
    // Convert italic
    html = html.replacingOccurrences(of: "\\*([^*]+)\\*", with: "<em>$1</em>", options: .regularExpression)
    
    // Convert horizontal rules
    html = html.replacingOccurrences(of: "(?m)^---+$", with: "<hr>", options: .regularExpression)
    
    // Convert tables
    html = convertTables(html)
    
    // Convert unordered lists
    html = html.replacingOccurrences(of: "(?m)^- (.+)$", with: "<li>$1</li>", options: .regularExpression)
    html = html.replacingOccurrences(of: "(<li>.*</li>\\n)+", with: "<ul>$0</ul>", options: .regularExpression)
    
    // Convert ordered lists  
    html = html.replacingOccurrences(of: "(?m)^\\d+\\. (.+)$", with: "<li>$1</li>", options: .regularExpression)
    
    // Convert blockquotes
    html = html.replacingOccurrences(of: "(?m)^> (.+)$", with: "<blockquote>$1</blockquote>", options: .regularExpression)
    
    // Convert paragraphs (double newlines)
    html = html.replacingOccurrences(of: "\n\n", with: "</p><p>")
    
    // Wrap in styled HTML document
    return """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <style>
        :root {
          color-scheme: light dark;
        }
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
          font-size: 14px;
          line-height: 1.6;
          padding: 24px;
          max-width: 900px;
          margin: 0 auto;
          background: transparent;
        }
        @media (prefers-color-scheme: dark) {
          body { color: #f0f0f0; }
          a { color: #58a6ff; }
          code { background: #2d2d2d; }
          pre { background: #1e1e1e; }
          table { border-color: #444; }
          th { background: #2d2d2d; }
          td { border-color: #444; }
          blockquote { border-color: #444; color: #aaa; }
          hr { border-color: #444; }
        }
        @media (prefers-color-scheme: light) {
          body { color: #1d1d1f; }
          a { color: #0066cc; }
          code { background: #f0f0f0; }
          pre { background: #f5f5f5; }
          blockquote { border-color: #ddd; color: #666; }
        }
        h1 { font-size: 28px; font-weight: 700; margin-top: 32px; }
        h2 { font-size: 22px; font-weight: 600; margin-top: 28px; border-bottom: 1px solid #444; padding-bottom: 8px; }
        h3 { font-size: 18px; font-weight: 600; margin-top: 24px; }
        h4 { font-size: 16px; font-weight: 600; margin-top: 20px; }
        code {
          font-family: 'SF Mono', Menlo, monospace;
          font-size: 13px;
          padding: 2px 6px;
          border-radius: 4px;
        }
        pre {
          padding: 16px;
          border-radius: 8px;
          overflow-x: auto;
        }
        pre code {
          padding: 0;
          background: transparent;
        }
        table {
          border-collapse: collapse;
          width: 100%;
          margin: 16px 0;
        }
        th, td {
          border: 1px solid #444;
          padding: 8px 12px;
          text-align: left;
        }
        th {
          font-weight: 600;
        }
        img {
          max-width: 100%;
          border-radius: 8px;
          box-shadow: 0 2px 8px rgba(0,0,0,0.2);
        }
        blockquote {
          margin: 16px 0;
          padding: 12px 20px;
          border-left: 4px solid;
          font-style: italic;
        }
        hr {
          border: none;
          border-top: 1px solid;
          margin: 24px 0;
        }
        ul, ol {
          padding-left: 24px;
        }
        li {
          margin: 4px 0;
        }
        a {
          text-decoration: none;
        }
        a:hover {
          text-decoration: underline;
        }
      </style>
    </head>
    <body>
      <p>\(html)</p>
    </body>
    </html>
    """
  }
  
  private func convertTables(_ text: String) -> String {
    var result = text
    let lines = text.components(separatedBy: "\n")
    var tableLines: [String] = []
    var inTable = false
    var tableStart = 0
    
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
        if !inTable {
          inTable = true
          tableStart = index
        }
        tableLines.append(line)
      } else if inTable {
        // End of table
        if tableLines.count >= 2 {
          let tableHTML = buildTableHTML(tableLines)
          let originalTable = tableLines.joined(separator: "\n")
          result = result.replacingOccurrences(of: originalTable, with: tableHTML)
        }
        tableLines = []
        inTable = false
      }
    }
    
    // Handle table at end of document
    if inTable && tableLines.count >= 2 {
      let tableHTML = buildTableHTML(tableLines)
      let originalTable = tableLines.joined(separator: "\n")
      result = result.replacingOccurrences(of: originalTable, with: tableHTML)
    }
    
    return result
  }
  
  private func buildTableHTML(_ lines: [String]) -> String {
    var html = "<table>"
    
    for (index, line) in lines.enumerated() {
      // Skip separator line (|---|---|)
      if line.contains("---") { continue }
      
      let cells = line.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
      
      if index == 0 {
        html += "<thead><tr>"
        for cell in cells {
          html += "<th>\(cell)</th>"
        }
        html += "</tr></thead><tbody>"
      } else {
        html += "<tr>"
        for cell in cells {
          html += "<td>\(cell)</td>"
        }
        html += "</tr>"
      }
    }
    
    html += "</tbody></table>"
    return html
  }
}
#endif

/// A view that displays the product manual with markdown rendering
public struct HelpView: View {
  @State private var markdownContent: String = ""
  @State private var searchText: String = ""
  @State private var selectedSection: String? = nil
  @State private var resourcesURL: URL? = nil
  @Environment(\.dismiss) private var dismiss
  
  // Table of contents extracted from markdown headers
  private var sections: [(title: String, level: Int, anchor: String)] {
    let lines = markdownContent.split(separator: "\n", omittingEmptySubsequences: false)
    var result: [(title: String, level: Int, anchor: String)] = []
    
    for line in lines {
      let trimmed = String(line)
      if trimmed.hasPrefix("## ") {
        let title = String(trimmed.dropFirst(3))
        let anchor = title.lowercased().replacingOccurrences(of: " ", with: "-")
          .replacingOccurrences(of: "&", with: "")
        result.append((title, 2, anchor))
      } else if trimmed.hasPrefix("### ") {
        let title = String(trimmed.dropFirst(4))
        let anchor = title.lowercased().replacingOccurrences(of: " ", with: "-")
          .replacingOccurrences(of: "&", with: "")
        result.append((title, 3, anchor))
      }
    }
    return result
  }
  
  public var body: some View {
    #if os(macOS)
    NavigationSplitView {
      // Sidebar with table of contents
      List(selection: $selectedSection) {
        Section("Table of Contents") {
          ForEach(sections, id: \.anchor) { section in
            HStack {
              if section.level == 3 {
                Spacer().frame(width: 16)
              }
              Text(section.title)
                .font(section.level == 2 ? .headline : .subheadline)
            }
            .tag(section.anchor)
          }
        }
      }
      .listStyle(.sidebar)
      .frame(minWidth: 220)
    } detail: {
      // Main content rendered as HTML
      MarkdownWebView(
        markdown: searchText.isEmpty ? markdownContent : filterContent(markdownContent, search: searchText),
        resourcesURL: resourcesURL
      )
    }
    .searchable(text: $searchText, prompt: "Search documentation")
    .navigationTitle("Help")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          openInFinder()
        } label: {
          Label("Show in Finder", systemImage: "folder")
        }
        .help("Show documentation files in Finder")
      }
    }
    .task {
      loadMarkdownContent()
    }
    #else
    Text("Help is available on macOS")
    #endif
  }
  
  private func loadMarkdownContent() {
    // Try to load from bundle
    if let bundleURL = Bundle.main.url(forResource: "PRODUCT_MANUAL", withExtension: "md"),
       let content = try? String(contentsOf: bundleURL, encoding: .utf8) {
      markdownContent = content
      // Set resources URL to the bundle's Resources directory for images
      resourcesURL = bundleURL.deletingLastPathComponent()
      return
    }
    
    // Fallback
    markdownContent = """
    # Peel Product Manual
    
    Documentation file not found. Please ensure PRODUCT_MANUAL.md is bundled with the app.
    """
  }
  
  private func filterContent(_ content: String, search: String) -> String {
    let searchLower = search.lowercased()
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    var result: [String] = []
    var currentSection: [String] = []
    var sectionHeader: String = ""
    var includeSection = false
    
    for line in lines {
      let lineStr = String(line)
      
      if lineStr.hasPrefix("## ") || lineStr.hasPrefix("### ") {
        if includeSection && !currentSection.isEmpty {
          result.append(sectionHeader)
          result.append(contentsOf: currentSection)
          result.append("")
        }
        
        sectionHeader = lineStr
        currentSection = []
        includeSection = lineStr.lowercased().contains(searchLower)
      } else {
        currentSection.append(lineStr)
        if lineStr.lowercased().contains(searchLower) {
          includeSection = true
        }
      }
    }
    
    if includeSection && !currentSection.isEmpty {
      result.append(sectionHeader)
      result.append(contentsOf: currentSection)
    }
    
    return result.isEmpty ? "# No Results\n\nNo matches found for \"\(search)\"" : result.joined(separator: "\n")
  }
  
  #if os(macOS)
  private func openInFinder() {
    if let url = resourcesURL {
      NSWorkspace.shared.selectFile(url.appendingPathComponent("PRODUCT_MANUAL.md").path, inFileViewerRootedAtPath: url.path)
    }
  }
  #endif
}

#Preview {
  HelpView()
    .frame(width: 1000, height: 700)
}
