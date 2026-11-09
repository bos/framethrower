import Foundation

struct OAuthCredentials: Sendable {
    static let bundled = OAuthCredentials(
        contentsOf: Bundle.main.url(forResource: "OAuthConfig", withExtension: "plist")
    )

    let googleClientID: String
    let googleClientSecret: String
    let slackClientID: String
    let slackClientSecret: String

    init(contentsOf url: URL?) {
        let values: [String: String]
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? PropertyListDecoder().decode([String: String].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
        googleClientID = values["GDriveClientID"] ?? ""
        googleClientSecret = values["GDriveClientSecret"] ?? ""
        slackClientID = values["SlackClientID"] ?? ""
        slackClientSecret = values["SlackClientSecret"] ?? ""
    }
}
