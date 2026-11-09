import Foundation

@main
struct OAuthCredentialsChecks {
    static func main() {
        let configured = OAuthCredentials(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(configured.googleClientID == "example-google")
        precondition(configured.googleClientSecret == "example-google-secret")
        precondition(configured.slackClientID == "example-slack")
        precondition(configured.slackClientSecret == "example-slack-secret")

        for url in [nil, URL(fileURLWithPath: CommandLine.arguments[2])] as [URL?] {
            let empty = OAuthCredentials(contentsOf: url)
            precondition(empty.googleClientID.isEmpty && empty.googleClientSecret.isEmpty)
            precondition(empty.slackClientID.isEmpty && empty.slackClientSecret.isEmpty)
        }
        print("OAuth credential resource checks passed")
    }
}
