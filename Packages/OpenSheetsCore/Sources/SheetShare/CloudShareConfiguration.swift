import Foundation
import SheetModel

/// Where the relay lives and how its two endpoints are spelled.
///
/// # Why the default is a placeholder that cannot work
///
/// The relay is a Cloudflare Worker somebody has to deploy into an account they own, and that
/// deploy is a user step, not an agent step (OPEN-1 in the Cloud Share plan). Until it happens
/// there is no honest value to compile in. A placeholder host that obviously is not a real
/// deployment is better than a plausible-looking one: ``isPlaceholder`` lets the settings pane
/// say "no relay configured yet" instead of showing a connection failing forever against a
/// domain that was never going to answer.
///
/// The one-line follow-up after the deploy is to change ``placeholderRelayOrigin`` to the
/// `workers.dev` origin the deploy printed. `OSCloudRelayURL` in `UserDefaults` overrides it in
/// the meantime, which is how development against a `wrangler dev` instance works.
public struct CloudShareConfiguration: Sendable, Equatable {
    /// The compiled-in default. Not a real deployment — see the type's note.
    public static let placeholderRelayOrigin = "https://opensheets-relay.example.workers.dev"

    /// The relay's HTTPS origin. Scheme and host only; paths come from this type.
    public var relayOrigin: URL

    /// Where the Mac's outbound socket connects, as a path on ``relayOrigin``.
    public var agentPath: String

    /// The prefix a link URL's token follows. Includes both slashes so the URL is pure string
    /// concatenation, which is what makes the link the owner copies predictable to the character.
    public var mcpPath: String

    public init(relayOrigin: URL, agentPath: String = "/agent", mcpPath: String = "/mcp/") {
        self.relayOrigin = relayOrigin
        self.agentPath = agentPath
        self.mcpPath = mcpPath
    }

    /// Parses an origin the user or a default supplied. Fails rather than repairing: a relay
    /// origin that had to be guessed at is a link that points somewhere nobody chose.
    public init?(relayOrigin text: String, agentPath: String = "/agent", mcpPath: String = "/mcp/") {
        guard let url = URL(string: text), url.scheme != nil, url.host() != nil else { return nil }
        self.init(relayOrigin: url, agentPath: agentPath, mcpPath: mcpPath)
    }

    /// The compiled-in configuration.
    ///
    /// The `??` is not defensive programming, it is the absence of a non-failable `URL(string:)`
    /// in Foundation, and this project does not force-unwrap. The right-hand side is unreachable
    /// for the literal above — `ShareTokenTests` pins exactly that — and it is a `file:` URL on
    /// purpose: if it ever were reached, ``agentURL()`` throws on the scheme rather than quietly
    /// connecting somewhere unintended.
    public static let standard = CloudShareConfiguration(
        relayOrigin: URL(string: placeholderRelayOrigin) ?? URL(fileURLWithPath: "/dev/null")
    )

    /// True while no relay has been deployed and pointed at (OPEN-1).
    public var isPlaceholder: Bool { relayOrigin.absoluteString == Self.placeholderRelayOrigin }

    /// The URL the owner copies and a recipient pastes into their assistant.
    ///
    /// Built by string concatenation rather than `URL.appendingPathComponent`, which percent-
    /// encodes what it is handed and normalises what it is not. Every character of a token is
    /// already URL-path-safe by construction (unpadded base64url plus two dots), so the naive
    /// spelling is also the exact one, and a link that survives a round trip through a chat app
    /// is worth more than a clever URL builder.
    public static func linkURL(origin: URL, token: ShareToken, mcpPath: String = "/mcp/") -> String {
        var text = origin.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text + mcpPath + token.rawValue
    }

    /// ``linkURL(origin:token:mcpPath:)`` against this configuration's origin.
    public func linkURL(for token: ShareToken) -> String {
        Self.linkURL(origin: relayOrigin, token: token, mcpPath: mcpPath)
    }

    /// The `wss://` URL the agent socket dials.
    ///
    /// Throws instead of coalescing to something plausible: every other value in this type is
    /// derived from ``relayOrigin``, so an origin that will not produce a socket URL is a
    /// configuration the owner has to fix, and saying so beats retrying against a URL nobody
    /// chose. `http` maps to `ws` so a local `wrangler dev` works without a second knob.
    public func agentURL() throws(SheetError) -> URL {
        guard let scheme = relayOrigin.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw .invalidArgument(
                name: "relayOrigin",
                reason: "a relay origin is an http or https URL, not '\(relayOrigin.absoluteString)'"
            )
        }
        guard var components = URLComponents(url: relayOrigin, resolvingAgainstBaseURL: false) else {
            throw .invalidArgument(
                name: "relayOrigin",
                reason: "'\(relayOrigin.absoluteString)' does not parse into URL components"
            )
        }
        components.scheme = scheme == "http" ? "ws" : "wss"
        components.path = agentPath
        guard let url = components.url else {
            throw .invalidArgument(
                name: "relayOrigin",
                reason: "'\(relayOrigin.absoluteString)' plus '\(agentPath)' is not a URL"
            )
        }
        return url
    }
}
