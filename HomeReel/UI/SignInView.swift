import SwiftUI

struct SignInView: View {
    @EnvironmentObject var app: AppModel
    @State private var manual = false
    @State private var address = ""
    @State private var token = ""

    var body: some View {
        VStack(spacing: 40) {
            Text("HomeReel").font(.largeTitle.bold())
            if case .linking(let code) = app.phase {
                VStack(spacing: 20) {
                    Text("On your phone or computer, go to").font(.title3)
                    Text("plex.tv/link").font(.title.bold())
                    Text("and enter this code").font(.title3)
                    Text(code).font(.system(size: 120, weight: .bold, design: .monospaced)).tracking(16)
                    ProgressView()
                    Button("Cancel") { app.cancelLinking() }
                }
            } else if manual {
                VStack(spacing: 24) {
                    TextField("Server address, for example 192.168.1.10", text: $address)
                    SecureField("Plex token", text: $token)
                    HStack(spacing: 40) {
                        Button("Connect") { Task { await app.signInManually(address: address, token: token) } }
                            .disabled(address.isEmpty || token.isEmpty)
                        Button("Back") { manual = false }
                    }
                }
                .frame(maxWidth: 900)
            } else {
                Text("Connect to your Plex server").font(.title2).foregroundStyle(.secondary)
                Button("Sign In with a Code") { app.signInWithCode() }
                Button("Enter Server Address and Token") { manual = true }
            }
        }
        .padding(80)
    }
}
