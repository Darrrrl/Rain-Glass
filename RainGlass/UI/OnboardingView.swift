import SwiftUI

struct WallpaperSetupView: View {
    @ObservedObject var wallpaper: WallpaperController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Welcome to RainGlass", systemImage: "cloud.rain")
                .font(.title2.bold())
            Text("Choose a wallpaper to start the rainy desktop. After setup, use the RainGlass icon in the menu bar for all controls.")
                .foregroundStyle(.secondary)
            if let error = wallpaper.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            Spacer(minLength: 4)
            HStack {
                if wallpaper.isLoading { ProgressView("Loading image…") }
                Spacer()
                Button("Choose Wallpaper…") { wallpaper.chooseImage() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 460, height: 230)
    }
}
