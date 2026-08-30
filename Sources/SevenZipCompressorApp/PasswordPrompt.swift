import SwiftUI
import CompressorCore

/// A password the app needs before it can go on.
struct PasswordRequest: Identifiable {
    enum Purpose {
        case compress(itemName: String)
        case extract(archiveName: String)
        case setShared

        var title: String {
            switch self {
            case .compress: "圧縮に使うパスワード"
            case .extract: "展開に必要なパスワード"
            case .setShared: "共通パスワード"
            }
        }

        var explanation: String {
            switch self {
            case .compress(let name): "「\(name)」を暗号化して圧縮します。"
            case .extract(let name): "「\(name)」は暗号化されています。パスワードを入力してください。"
            case .setShared: "「毎回共通」で使うパスワードです。キーチェーンに保存します。"
            }
        }

        var needsConfirmation: Bool {
            switch self {
            case .compress, .setShared: true    // typing it wrong would lock the archive
            case .extract: false
            }
        }
    }

    let id = UUID()
    let purpose: Purpose
    let prefill: String
    /// nil means the user cancelled.
    let completion: (Password?) -> Void
}

struct PasswordPromptSheet: View {
    let request: PasswordRequest

    @State private var password: String = ""
    @State private var confirmation: String = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.purpose.title).font(.headline)
            Text(request.purpose.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("パスワード", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            if request.purpose.needsConfirmation {
                SecureField("確認のためもう一度", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("キャンセル") { request.completion(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            password = request.prefill
            confirmation = request.purpose.needsConfirmation ? request.prefill : ""
            focused = true
        }
    }

    private func submit() {
        if request.purpose.needsConfirmation, password != confirmation {
            problem = "2 つの入力が一致しません。"
            return
        }
        do {
            request.completion(try Password(password))
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
