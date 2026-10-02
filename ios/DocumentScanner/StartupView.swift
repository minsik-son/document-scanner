import SwiftUI

struct StartupView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            VStack(spacing: 24) {
                Image("LaunchLogo")
                    .resizable().scaledToFit().frame(width: 168, height: 168)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Document Scanner").font(.system(.title2, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Paper, made digital.").font(.body)
                        .foregroundStyle(Color(red: 0.55, green: 0.80, blue: 0.95))
                }
            }.padding(.horizontal, 24).offset(y: -20)
            VStack {
                Spacer()
                ProgressView().tint(.white).accessibilityLabel("Opening your documents")
                    .padding(.bottom, 42)
            }
        }.accessibilityIdentifier("startup-screen")
    }
}
