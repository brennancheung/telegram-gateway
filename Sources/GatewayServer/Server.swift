import Foundation
import GatewayCore
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore

/// Builds the Hummingbird application for docs/api.md: every route in the endpoint index,
/// bound to `127.0.0.1` only. The daemon runs it; tests drive it in-process.
public enum GatewayServer {
    public static func buildRouter(deps: Dependencies) -> Router<GatewayRequestContext> {
        let router = Router(context: GatewayRequestContext.self)
        router.add(middleware: ErrorMiddleware(logger: deps.logger))

        let open = router.group("/v1")
        PublicRoutes(deps: deps).register(on: open)
        // The stream authenticates after the upgrade (close code 4401): a refused upgrade
        // cannot carry a JSON 401 through the WebSocket channel.
        EventStream(deps: deps).register(on: open)

        let authed = router.group("/v1").add(middleware: AuthMiddleware(grants: deps.grants, rateLimiter: deps.rateLimiter))
        AppRoutes(deps: deps).register(on: authed)

        let admin = authed.group("/admin").add(middleware: AdminOnlyMiddleware())
        AdminRoutes(deps: deps).register(on: admin)
        return router
    }

    public static func buildApplication(deps: Dependencies, port: Int, logger: Logger) -> Application<RouterResponder<GatewayRequestContext>> {
        let router = buildRouter(deps: deps)
        return Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "TelegramGateway"),
            logger: logger
        )
    }
}
