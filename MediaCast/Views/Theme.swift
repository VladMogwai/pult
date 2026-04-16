import SwiftUI

// MARK: - Color tokens

enum Theme {
    // backgrounds
    static let bgPrimary   = Color(hex: "#07070F")
    static let bgSecondary = Color(hex: "#0E0E1C")
    static let bgTertiary  = Color(hex: "#12121E")

    // borders
    static let borderSubtle = Color(hex: "#1A1A2E")
    static let borderMid    = Color(hex: "#22223A")

    // accent
    static let accent    = Color(hex: "#C940FF")
    static let accentDim = Color(hex: "#8A20CC")
    static let accentBg  = Color(hex: "#18082A")

    // cast active (green — unchanged, signals live connection)
    static let castActive   = Color(hex: "#00C37A")
    static let castActiveBg = Color(hex: "#061A10")

    // text
    static let textPrimary   = Color(hex: "#F0F0FF")
    static let textSecondary = Color(hex: "#6A6A8E")
    static let textMuted     = Color(hex: "#3A3A5A")

    // semantic
    static let danger   = Color(hex: "#E03E3E")
    static let dangerBg = Color(hex: "#1A0808")
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8)  & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - ChipView

struct ChipView: View {
    let label: String
    let isActive: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            .foregroundColor(isActive ? Theme.accent : Theme.textSecondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive ? Theme.accentBg : Theme.bgTertiary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                isActive ? Theme.accent : Theme.borderSubtle,
                                lineWidth: isActive ? 1.0 : 0.5
                            )
                    )
            )
    }
}
