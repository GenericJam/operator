import LocalAuthentication
import SwiftUI
import UIKit

// The approve chip for self-changes: the system screen-lock prompt behind a
// chip, a `Mob.UI.native_view` registered as "Operator_Core_ApproveButton"
// (driven by `Operator.Core.ApproveButton`), the iOS side of
// OperatorApproval.kt.
//
// Tap: LAContext's `.deviceOwnerAuthentication`, which takes Face ID or Touch
// ID and falls back to the device passcode. Props `title` and `subtitle` make
// the prompt's reason (shown by Touch ID and the passcode screen; Face ID
// shows none).
//
// Events: `approved` {}, `failed` {"reason": "canceled" | "lockout" |
// "mismatch" | "error_<LAError code>"}, `unavailable` {} (no passcode set),
// each tagged with the `request` prop the prompt was opened for; a prompt
// whose chip moves on to another `request`, or whose screen is left, is
// dropped and reports nothing.
enum OperatorApproval {
    static let name = "Operator_Core_ApproveButton"

    static func register() {
        MobNativeViewRegistry.shared.register(name) { props, send in
            AnyView(OperatorApproveButton(props: props, send: send))
        }
    }

    /// The event for an LAContext error: `unavailable` without a passcode,
    /// else `failed` with the reason `Operator.Core.ApproveButton.why/2` reads.
    static func outcome(_ error: Error?) -> (event: String, payload: [String: Any]) {
        guard let error = error as? LAError else {
            return ("failed", ["reason": "error_unknown"])
        }
        switch error.code {
        case .passcodeNotSet:
            return ("unavailable", [:])
        case .userCancel, .systemCancel, .appCancel, .userFallback:
            return ("failed", ["reason": "canceled"])
        case .biometryLockout:
            return ("failed", ["reason": "lockout"])
        case .authenticationFailed:
            return ("failed", ["reason": "mismatch"])
        default:
            return ("failed", ["reason": "error_\(error.code.rawValue)"])
        }
    }
}

/// The prompt on screen for one chip, if any. `active` lets one result
/// through, tagged with the `request` the prompt was opened for; leaving
/// the screen, or the chip moving on to another request, drops the prompt
/// and reports nothing.
final class OperatorApprovalState: ObservableObject {
    @Published private(set) var busy = false
    /// The latest render's `send` (the registry makes one per render).
    var send: MobNativeSend?
    private var context: LAContext?
    private var active = false
    private var request = ""

    func prompt(reason: String, request: String) {
        guard !active else { return }
        let context = LAContext()
        self.context = context
        self.request = request
        active = true
        busy = true

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            let (event, payload) = OperatorApproval.outcome(error)
            finish(event, payload)
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] ok, error in
            DispatchQueue.main.async {
                guard let self, self.context === context else { return }
                if ok {
                    self.finish("approved")
                } else {
                    let (event, payload) = OperatorApproval.outcome(error)
                    self.finish(event, payload)
                }
            }
        }
    }

    func cancel() {
        active = false
        busy = false
        context?.invalidate()
        context = nil
    }

    private func finish(_ event: String, _ payload: [String: Any] = [:]) {
        guard active else { return }
        active = false
        context = nil
        busy = false
        send?(event, payload.merging(["request": request]) { _, tagged in tagged })
    }

    deinit {
        context?.invalidate()
    }
}

struct OperatorApproveButton: View {
    let props: [String: Any]
    let send: MobNativeSend
    @StateObject private var approval = OperatorApprovalState()
    // mob keeps a screen it navigated away from in the tree, parked:
    // onDisappear doesn't fire, this does.
    @Environment(\.mobScreenIsActive) private var isActive

    var body: some View {
        approval.send = send
        let textColor = operatorColor(props["text_color"], default: 0xFFE6E6E6)
        let label = props["label"] as? String ?? "approve"
        let title = props["title"] as? String ?? "Approve"
        let subtitle = props["subtitle"] as? String ?? ""
        let reason = subtitle.isEmpty ? title : "\(title). \(subtitle)"
        let request = props["request"] as? String ?? ""
        let size = operatorFloat(props["text_size"], default: 15)
        // Without a `font` the system face, as Android's FontFamily.Default.
        let font = (props["font"] as? String).flatMap { UIFont(name: $0, size: size) } ?? .systemFont(ofSize: size)

        return Text(label)
            .font(Font(font))
            .foregroundColor(textColor.opacity(approval.busy ? 0.5 : 1))
            .padding(6)
            .background(operatorColor(props["background"], default: 0xFF161B22))
            .contentShape(Rectangle())
            .onTapGesture {
                if isActive, !approval.busy { approval.prompt(reason: reason, request: request) }
            }
            .accessibilityAddTraits(.isButton)
            .onChange(of: request) { approval.cancel() }
            .onChange(of: isActive) { _, active in if !active { approval.cancel() } }
            .onDisappear { approval.cancel() }
    }
}

/// An ARGB integer prop (as `Operator.Core.Term.color/2` makes them).
func operatorUIColor(_ value: Any?, default fallback: Int64) -> UIColor {
    let argb = (value as? NSNumber)?.int64Value ?? fallback
    return UIColor(
        red: CGFloat((argb >> 16) & 0xFF) / 255,
        green: CGFloat((argb >> 8) & 0xFF) / 255,
        blue: CGFloat(argb & 0xFF) / 255,
        alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
}

func operatorColor(_ value: Any?, default fallback: Int64) -> Color {
    Color(operatorUIColor(value, default: fallback))
}

func operatorFloat(_ value: Any?, default fallback: CGFloat) -> CGFloat {
    (value as? NSNumber).map { CGFloat($0.doubleValue) } ?? fallback
}

/// A bundled face by its PostScript name, else the system monospace.
func operatorFont(_ name: String?, size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
    if let name, !name.isEmpty, let font = UIFont(name: name, size: size) {
        return font
    }
    let mono = UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    guard italic, let descriptor = mono.fontDescriptor.withSymbolicTraits(.traitItalic) else { return mono }
    return UIFont(descriptor: descriptor, size: size)
}
