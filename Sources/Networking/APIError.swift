import Foundation

enum APIError: Error {
    case invalidURL
    case unauthorized
    case forbidden
    case server(statusCode: Int)
    case decoding
    case transport(String)
}
