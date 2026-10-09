import AppIntents
import Foundation

// Siri & Shortcuts:
//   "Hey Siri, ask Marquee"  → "What would you like?" → "pause the lounge TV" / "what's new" / "how much time does Zoey have left"
//   "Hey Siri, play something in Marquee" → "What should I play?" → "Bluey"
// Both also appear in the Shortcuts app, so they can go in automations (e.g. "Movie night" at 7pm Friday).

@available(iOS 16.0, *)
struct AskMarqueeIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Marquee"
    static var description = IntentDescription("Control Marquee or ask it something — “pause the lounge TV”, “what's new”, “start movie night”.")

    @Parameter(title: "Request", requestValueDialog: IntentDialog("What would you like?"))
    var request: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = try await MarqueeAssistant.ask(request)
        var speech = reply.speech
        if let url = reply.openURL {
            // Siri can't jump into the app from here — line it up for the next time Marquee opens
            await MainActor.run { Router.openURL(url) }
            if reply.playsHere { speech += ". Open Marquee to watch, or say “play something in Marquee”." }
        }
        return .result(dialog: IntentDialog(stringLiteral: speech))
    }
}

@available(iOS 16.0, *)
struct PlayInMarqueeIntent: AppIntent {
    static var title: LocalizedStringResource = "Play in Marquee"
    static var description = IntentDescription("Find a movie or show and start playing it.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Title", requestValueDialog: IntentDialog("What should I play?"))
    var title: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = try await MarqueeAssistant.ask("play \(title)")
        if let url = reply.openURL { Router.openURL(url) }
        return .result(dialog: IntentDialog(stringLiteral: reply.speech))
    }
}

@available(iOS 16.0, *)
struct MarqueeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskMarqueeIntent(), phrases: ["Ask \(.applicationName)", "Tell \(.applicationName)", "\(.applicationName) remote"],
                    shortTitle: "Ask Marquee", systemImageName: "bubble.left")
        AppShortcut(intent: PlayInMarqueeIntent(), phrases: ["Play something in \(.applicationName)", "Watch something on \(.applicationName)"],
                    shortTitle: "Play in Marquee", systemImageName: "play.rectangle")
    }
}

/// Talks to Marquee's voice-command endpoint with the app's device key.
enum MarqueeAssistant {
    struct Reply { let speech: String; let openURL: URL?; var playsHere = false }

    static func ask(_ text: String) async throws -> Reply {
        guard SharedStore.deviceKey != nil, !SharedStore.candidates.isEmpty else {
            return Reply(speech: "Open Marquee and pick your profile first.", openURL: nil)
        }
        do {
            // Home on your Wi-Fi, away (Tailscale) everywhere else
            let (found, reply) = await SharedStore.fetch("/api/assistant", method: "POST", json: ["text": text])
            guard let data = found, let response = reply else { throw URLError(.cannotConnectToHost) }
            if response.statusCode == 401 {
                SharedStore.deviceKey = nil
                return Reply(speech: "Open Marquee once so I can sign in again.", openURL: nil)
            }
            let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            let speech = (json["speech"] as? String) ?? "Done."
            let action = json["action"] as? [String: Any]
            let type = action?["type"] as? String
            var url: URL? = nil
            if let s = action?["url"] as? String, ["play", "movienight", "suggest", "open"].contains(type ?? "") { url = URL(string: s) }
            return Reply(speech: speech, openURL: url, playsHere: type == "play")
        } catch {
            return Reply(speech: "I can't reach Marquee right now. Is Tailscale on?", openURL: nil)
        }
    }
}
