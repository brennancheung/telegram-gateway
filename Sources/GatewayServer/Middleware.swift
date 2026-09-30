import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import Logging

/// Outermost middleware: stamps `X-TGW-Request-Id` on every response, turns errors into the
/// documented JSON shape, and answers unknown routes with `404 not_found`.
struct ErrorMiddleware: RouterMiddleware {
    typealias Context = GatewayRequestContext
    let logger: Logger

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var response: Response
        do {
            response = try await next(request, context)
        } catch let error as APIError {
            response = render(error)
        } catch let error as HTTPError {
            response = render(map(error))
        } catch let error as any HTTPResponseError {
            response = render(map(HTTPError(error.status)))
        } catch let error as EventLog.PageError {
            if case .historyPruned(let oldest) = error { response = render(APIError.historyPruned(oldestSeq: oldest)) } else { response = render(.internalError("event log")) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("request \(context.requestId) \(request.method) \(request.uri.path): \(error)")
            response = render(APIError.internalError("Unexpected error; report with X-TGW-Request-Id \(context.requestId)."))
        }
        response.headers[.requestId] = context.requestId
        return response
    }

    private func map(_ error: HTTPError) -> APIError {
        switch error.status {
        case .notFound: .notFound
        case .contentTooLarge: .payloadTooLarge
        case .badRequest: .invalidRequest("request", error.body ?? "malformed request")
        case .methodNotAllowed: .notFound
        default: APIError(status: Int(error.status.code), code: error.status.code >= 500 ? "internal" : "invalid_request", message: error.body ?? error.status.reasonPhrase)
        }
    }

    func render(_ error: APIError) -> Response {
        var headers: [(HTTPField.Name, String)] = []
        for (name, value) in error.headers {
            if let field = HTTPField.Name(name) { headers.append((field, value)) }
        }
        return json(error.json, status: HTTPResponse.Status(code: error.status), headers: headers)
    }
}

/// Resolves the bearer token into a `Principal`, applies the per-token request budget
/// (600/min) and adds `X-RateLimit-*` to the response (docs/api.md "Rate limits").
struct AuthMiddleware: RouterMiddleware {
    typealias Context = GatewayRequestContext
    static let requestsPerMinute = 600

    let grants: Grants
    let rateLimiter: RateLimiter

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let principal = try await grants.authenticate(bearer: AuthMiddleware.bearer(request))
        let decision = await rateLimiter.hit("token:\(principal.rateLimitKey)", limit: AuthMiddleware.requestsPerMinute)
        let limitHeaders: [(HTTPField.Name, String)] = [(.rateLimitLimit, String(decision.limit)), (.rateLimitRemaining, String(decision.remaining))]
        guard decision.allowed else {
            var error = APIError.rateLimited(retryAfter: decision.retryAfter)
            error.headers += limitHeaders.map { ($0.0.rawName, $0.1) }
            throw error
        }
        var context = context
        context.principal = principal
        context.rateLimit = (decision.limit, decision.remaining)
        var response = try await next(request, context)
        for (name, value) in limitHeaders { response.headers[name] = value }
        return response
    }

    static func bearer(_ request: Request) -> String? {
        guard let header = request.headers[.authorization] else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
}

/// `/v1/admin/*`: the principal must be the admin token.
struct AdminOnlyMiddleware: RouterMiddleware {
    typealias Context = GatewayRequestContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard try context.requirePrincipal().isAdmin else { throw APIError.adminOnly }
        return try await next(request, context)
    }
}
