
import Foundation
import Vapor
import NIO
import Cache

class Client {
    enum Error: Swift.Error {
        case emptyResponse
        case failedDecoding
        case invalidURL(URL)
    }

    let base: URL
    let imagesBase: URL
    let apiKey: String
    let cache: MemoryStorage<URL, HTTPClient.Response>?

    var eventLoop: EventLoopGroup {
        return httpClient.eventLoopGroup
    }

    private let httpClient: HTTPClient

    init(base: URL, imagesBase: URL, apiKey: String, httpClient: HTTPClient, cache: MemoryStorage<URL, HTTPClient.Response>? = nil) {
        self.base = base
        self.imagesBase = imagesBase
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.cache = cache
    }

    deinit {
        httpClient.shutdown { [httpClient] error in
            _ = httpClient
            guard let error = error else { return }
            print("Error shutting down client \(error)")
        }
    }

    func get<T: Decodable>(at path: [PathComponent], query: [String : String] = [:], expiry: Expiry = .seconds(30 * 60), type: T.Type = T.self) -> EventLoopFuture<T> {
        let composed = path.reduce(base) { $0.appendingPathComponent($1.description) }

        guard var components = URLComponents(url: composed, resolvingAgainstBaseURL: true) else {
            return httpClient.eventLoopGroup.future(error: Error.invalidURL(composed))
        }

        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "api_key", value: apiKey)]

        guard let url = components.url else { return httpClient.eventLoopGroup.future(error: Error.invalidURL(composed)) }

        if let cached = try? cache?.object(forKey: url) {
            return eventLoop.tryFuture {
                try cached.decode(type: type)
            }
        }
        return httpClient
            .get(url: url.absoluteString)
            .always { [weak cache] result in
                guard case .success(let response) = result else { return }
                cache?.setObject(response, forKey: url, expiry: expiry)
            }
            .decode(type: type)
    }

    func get<T: Decodable>(at path: PathComponent..., query: [String : String] = [:], expiry: Expiry = .seconds(30 * 60), type: T.Type = T.self) -> EventLoopFuture<T> {
        return get(at: path, query: query, expiry: expiry, type: type)
    }

    func get<T: Decodable>(at path: PathComponent..., query: [String : String] = [:], expiry: Expiry = .seconds(30 * 60)) -> EventLoopFuture<Paging<T>> {
        return get(at: path, query: query, expiry: expiry, type: Page<T>.self).map { page in
            return Paging(client: self, first: page, path: path, query: query)
        }
    }
}

extension EventLoopFuture where Value == HTTPClient.Response {

    fileprivate func decode<T: Decodable>(type: T.Type = T.self) -> EventLoopFuture<T> {
        return flatMapThrowing { try $0.decode(type: type) }
    }

}

extension HTTPClient.Response {

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        decoder.dateDecodingStrategy = JSONDecoder.DateDecodingStrategy.formatted(dateFormatter)
        return decoder
    }()

    fileprivate func decode<T: Decodable>(type: T.Type = T.self) throws -> T {
        guard let buffer = body else {
            throw Client.Error.emptyResponse
        }

        let length = buffer.readableBytes
        do {
            guard let data = try buffer.getJSONDecodable(type, decoder: Self.decoder, at: 0, length: length) else {
                throw Client.Error.failedDecoding
            }

            return data
        } catch {
            print(error)
            throw error
        }
    }

}
