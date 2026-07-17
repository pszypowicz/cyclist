import SwiftUI

private let repoURL = URL(string: "https://github.com/pszypowicz/cyclist")!
private let sponsorURL = URL(string: "https://github.com/sponsors/pszypowicz")!

struct AboutView: View {
    private let version: String = {
        let base = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "\(base) (beta)"
    }()

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Cyclist")
                .font(.title.bold())

            Text("Version \(version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("by Przemysław Szypowicz")
                .font(.subheadline)

            Divider()

            Link(destination: repoURL) {
                Label("GitHub Repository", systemImage: "link")
            }

            Link(destination: sponsorURL) {
                HStack(spacing: 4) {
                    Text("Support this project")
                    Image(systemName: "heart.fill")
                }
            }
            .foregroundStyle(.pink)
        }
        .padding(24)
        .frame(width: 260)
    }

    static func showWindow() {
        UtilityWindow.show(id: "about-cyclist", title: "About Cyclist", content: AboutView())
    }
}
