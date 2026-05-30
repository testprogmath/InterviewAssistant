//
//  MarkdownText.swift
//  InterviewAssistant
//
//  Inline-markdown rendering for short text snippets from LLMs.
//  Handles **bold**, *italic*, `code`, [links] and preserves line breaks.
//  Block-level constructs (#headings, ```code fences, lists) are left
//  alone — our analysis cards already format lists themselves.
//

import SwiftUI

extension String {
    /// Parse `self` as inline Markdown into an `AttributedString`. Falls
    /// back to plain text on parse error.
    var asInlineMarkdown: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: self, options: options) {
            return attributed
        }
        return AttributedString(self)
    }
}

extension Text {
    /// Convenience for the common pattern `Text(string.asInlineMarkdown)`.
    init(markdown source: String) {
        self.init(source.asInlineMarkdown)
    }
}
