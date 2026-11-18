import Foundation
import HTTPTypes
import OpenAPIRuntime

actor MemosAPIRoutingMiddleware: ClientMiddleware {
    private var usesUnversionedAPI: Bool?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await route(request, body: body, baseURL: baseURL, operationID: operationID, retryRead: true, next: next)
    }

    private func route(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        retryRead: Bool,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if usesUnversionedAPI == nil {
            var profileRequest = request
            profileRequest.method = .get
            profileRequest.path = "/api/v1/instance/profile"
            profileRequest.headerFields[.contentLength] = nil
            profileRequest.headerFields[.contentType] = nil
            var result = try await next(profileRequest, nil, baseURL)
            var unversioned = false
            if result.0.status == .notFound || result.0.status == .gone || isHTML(result.0) {
                profileRequest.path = "/api/instance/profile"
                result = try await next(profileRequest, nil, baseURL)
                unversioned = true
            }
            guard (200..<300).contains(result.0.status.code), !isHTML(result.0) else {
                return result
            }
            usesUnversionedAPI = unversioned
            if operationID == "InstanceService_GetInstanceProfile" {
                return result
            }
        }

        var routedRequest = request
        let versioned = usesUnversionedAPI == false
        if !versioned, let path = request.path, path.hasPrefix("/api/v1/") {
            routedRequest.path = "/api/" + path.dropFirst("/api/v1/".count)
        }
        let result = try await next(routedRequest, body, baseURL)
        if versioned, result.0.status == .gone {
            // A live upgrade can remove previously negotiated routes. Re-probe;
            // leave writes to the existing pending-operation retry.
            if usesUnversionedAPI == false { usesUnversionedAPI = nil }
            if retryRead, request.method == .get {
                return try await route(request, body: body, baseURL: baseURL, operationID: operationID, retryRead: false, next: next)
            }
        }
        return result
    }

    private func isHTML(_ response: HTTPResponse) -> Bool {
        (200..<300).contains(response.status.code) &&
            response.headerFields[.contentType]?.lowercased().hasPrefix("text/html") == true
    }
}
