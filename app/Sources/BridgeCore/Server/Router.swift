import Foundation

/// One parsed HTTP/1.1 request; the query is percent-decoded.
public struct HTTPRequest: Sendable, Equatable {
  public var method: String
  public var path: String
  public var query: [String: String]
  public var body: Data

  /// Decodes the JSON body, throwing `DecodingError` when it does not match `type`.
  public func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: body)
  }
}

/// A response with a JSON body (or none). The server adds the framing headers.
public struct HTTPResponse: Sendable, Equatable {
  public var status: Int
  public var body: Data

  public init(status: Int, body: Data = Data()) {
    self.status = status
    self.body = body
  }

  public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
    guard let body = try? JSONEncoder().encode(value) else {
      return error(500, "the reply could not be encoded")
    }
    return HTTPResponse(status: status, body: body)
  }

  /// An error reply: `400` schema, `404` unknown session, `409` unknown or stale request id,
  /// `410` a session the owner removed (with its `code`), `413` body too large.
  public static func error(_ status: Int, _ message: String, code: ErrorCode? = nil) -> HTTPResponse
  {
    json(ErrorReply(error: message, code: code), status: status)
  }
}

/// Answers the bridge's routes. The server calls it once per request.
public protocol Router: Sendable {
  func handle(_ req: HTTPRequest) async -> HTTPResponse
}
