//
//  GoPanelStyle.swift
//  Go
//
//  Building blocks for the menu bar panel, in the style of macOS Control
//  Center: frosted glass, grouped rounded cards, icon tiles and switches.
//

import AppKit
import SwiftUI

enum GoPanelMetrics {
    static let cornerRadius: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let inset: CGFloat = 12
}

// MARK: - Glass

/// The real macOS frosted material, blurring whatever is behind the panel.
struct GoGlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - Cards and rows

/// A grouped, rounded card of rows, like a Control Center module.
struct GoPanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: GoPanelMetrics.cardRadius, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GoPanelMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

/// A thin divider inset past a row's icon tile.
struct GoPanelRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 48)
    }
}

/// A small tinted rounded square holding an SF Symbol.
struct GoIconTile: View {
    let systemName: String
    var tint: Color = DS.Colors.accent

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 26, height: 26)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// Icon tile, title and optional subtitle, with a control on the right.
struct GoPanelRow<Trailing: View>: View {
    let icon: String
    var tint: Color = DS.Colors.accent
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            GoIconTile(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// A row whose control is a sliding switch.
struct GoPanelSwitchRow: View {
    let icon: String
    var tint: Color = DS.Colors.accent
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        GoPanelRow(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DS.Colors.accent)
        }
    }
}

// MARK: - Buttons

/// A pill button: filled for the main action, frosted otherwise.
struct GoPillButtonStyle: ButtonStyle {
    var prominent = true
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fullWidth ? 13 : 11, weight: .semibold))
            .foregroundStyle(prominent ? DS.Colors.textOnAccent : DS.Colors.textPrimary)
            .padding(.horizontal, fullWidth ? 16 : 11)
            .padding(.vertical, fullWidth ? 9 : 4)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? AnyShapeStyle(DS.Colors.accent.gradient) : AnyShapeStyle(Color.white.opacity(0.12)))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A full-width menu-style row that highlights under the pointer.
struct GoMenuRowButton: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }
            .foregroundStyle(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

// MARK: - Key caps

/// A keyboard key, for showing the push-to-talk shortcut.
struct GoKeyCap: View {
    let symbol: String
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Text(symbol).font(.system(size: 12, weight: .semibold))
            Text(name).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(DS.Colors.textPrimary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 1)
        )
        .accessibilityLabel(name)
    }
}
