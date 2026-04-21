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
    var isDownloaded: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                                    isActive ? Theme.accent : (isDownloaded ? Theme.castActive.opacity(0.5) : Theme.borderSubtle),
                                    lineWidth: isActive ? 1.0 : (isDownloaded ? 1.0 : 0.5)
                                )
                        )
                )
            if isDownloaded {
                Circle()
                    .fill(Theme.castActive)
                    .frame(width: 7, height: 7)
                    .offset(x: 3, y: -3)
            }
        }
    }
}

// MARK: - DocumentRevealButton
// Opens UIDocumentInteractionController so the user can preview the file or open it in Files.app

struct DocumentRevealButton: UIViewRepresentable {
    let fileURL: URL

    func makeUIView(context: Context) -> UIButton {
        let btn = UIButton(type: .system)
        let img = UIImage(systemName: "arrow.up.forward.app")
        btn.setImage(img, for: .normal)
        btn.tintColor = UIColor(Theme.textSecondary)
        btn.backgroundColor = UIColor(Theme.bgTertiary)
        btn.layer.cornerRadius = 7
        btn.addTarget(context.coordinator, action: #selector(Coordinator.tapped(_:)), for: .touchUpInside)
        return btn
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(fileURL: fileURL) }

    final class Coordinator: NSObject, UIDocumentInteractionControllerDelegate {
        let fileURL: URL
        var dic: UIDocumentInteractionController?

        init(fileURL: URL) { self.fileURL = fileURL }

        @objc func tapped(_ sender: UIButton) {
            dic = UIDocumentInteractionController(url: fileURL)
            dic?.delegate = self
            dic?.presentPreview(animated: true)
        }

        func documentInteractionControllerViewControllerForPreview(
            _ controller: UIDocumentInteractionController
        ) -> UIViewController {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first ?? UIViewController()
        }
    }
}
