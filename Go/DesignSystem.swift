//
//  DesignSystem.swift
//  Go
//
//  Colors, spacing and corner radii shared by Go's panel and overlay.
//

import SwiftUI
import AppKit

enum DS {

    enum Colors {
        // Surfaces and borders
        static let background = Color(hex: "#101211")
        static let surface2 = Color(hex: "#202221")
        static let borderSubtle = Color(hex: "#373B39")

        // Text
        static let textPrimary = Color(hex: "#ECEEED")
        static let textSecondary = Color(hex: "#ADB5B2")
        static let textTertiary = Color(hex: "#6B736F")
        /// Near-black on the green accent (about 8:1 contrast); white would be 2.6:1.
        static let textOnAccent = Color(hex: "#0B1A0A")
        static let codeText = Color(hex: "#9DC2FF")

        // Accent
        static let blue400 = Color(hex: "#60a5fa")
        static let accent = Color(hex: "#5BB450")

        // Status
        static let destructive = Color(hex: "#E5484D")
        /// Brighter red for text on dark backgrounds.
        static let destructiveText = Color(hex: "#FF6369")
        static let success = Color(hex: "#34D399")
        static let warning = Color(hex: "#FFB224")

        /// The cursor, its bubbles and the highlight box.
        static let overlayCursor = Color(hex: "#5BB450")
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
    }

    enum CornerRadius {
        static let medium: CGFloat = 8
        static let large: CGFloat = 10
    }
}

// MARK: - Pointer cursor

extension View {
    /// Shows the pointing-hand cursor over this view.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

/// Cursor rects are managed by the window, so they don't fight SwiftUI's own
/// hover handling the way `NSCursor.push()`/`pop()` can.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Color from hex

extension Color {
    /// A color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }
}
