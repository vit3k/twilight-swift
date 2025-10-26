//
//  SunshineClient.swift
//  twilight
//
//  Created by Pawel Witkowski on 25/10/2025.
//

import Foundation
import Security
import XMLCoder

// Internal helper to load SecIdentity (and optional cert chain) from PKCS12 file
private func loadIdentity(fromPKCS12 path: String, password: String) -> (
    identity: SecIdentity, certificates: [SecCertificate]
)? {
    let url = URL(fileURLWithPath: path)
    print("Attempting to read PKCS#12 at: \(url.path)")

    guard let p12Data = try? Data(contentsOf: url) else {
        print("Failed to read PKCS12 file at \(url.path). Check the path and working directory.")
        return nil
    }

    let options: [String: Any] = [kSecImportExportPassphrase as String: password]
    var itemsCF: CFArray?
    let status = SecPKCS12Import(p12Data as NSData, options as NSDictionary, &itemsCF)

    guard status == errSecSuccess else {
        print("SecPKCS12Import failed with status: \(status)")
        return nil
    }

    guard let items = itemsCF as? [[String: Any]], !items.isEmpty else {
        print("SecPKCS12Import returned no items.")
        return nil
    }

    // Find the first item that actually contains an identity
    for item in items {
        if let identityAny = item[kSecImportItemIdentity as String] {
            // Optional: extract cert chain if present
            let certs = (item[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
            let identity = identityAny as! SecIdentity
            return (identity, certs)
        }
    }

    print(
        "No SecIdentity found in PKCS#12. The file may contain only certificates without a private key."
    )
    return nil
}

// URLSessionDelegate to supply client identity during TLS handshake
private final class ClientCertificateDelegate: NSObject, URLSessionDelegate {
    let identity: SecIdentity
    let certificates: [SecCertificate]

    init(identity: SecIdentity, certificates: [SecCertificate]) {
        self.identity = identity
        self.certificates = certificates
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {

        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            // Provide identity and chain (some servers require the chain)
            let credential = URLCredential(
                identity: identity,
                certificates: certificates.isEmpty ? nil : certificates,
                persistence: .permanent)
            completionHandler(.useCredential, credential)

        case NSURLAuthenticationMethodServerTrust:
            if let trust = challenge.protectionSpace.serverTrust {
                // WARNING: For demonstration only. Do proper server trust evaluation in production.
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// Public-facing client that hides PKCS#12 loading and URLSession details
final class SunshineClient {
    private let session: URLSession
    private let scheme: String
    private let host: String
    private let port: Int?
    private let uniqueId: String

    // Designated initializer takes PKCS#12 credentials and the shared endpoint
    init?(
        p12Path: String,
        password: String,
        scheme: String = "https",
        host: String,
        port: Int? = nil,
        uniqueId: String
    ) {
        guard let (identity, chain) = loadIdentity(fromPKCS12: p12Path, password: password) else {
            return nil
        }
        let delegate = ClientCertificateDelegate(identity: identity, certificates: chain)
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        self.scheme = scheme
        self.host = host
        self.port = port
        self.uniqueId = uniqueId
    }

    // Convenience initializer that generates a uniqueId if not provided
    convenience init?(
        p12Path: String,
        password: String,
        scheme: String = "https",
        host: String,
        port: Int? = nil
    ) {
        self.init(
            p12Path: p12Path,
            password: password,
            scheme: scheme,
            host: host,
            port: port,
            uniqueId: UUID().uuidString)
    }

    // Build URL with stored host/port and provided path/query parameters
    private func buildURL(path: String, queryParameters: [String: String]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port { components.port = port }
        components.path = path.hasPrefix("/") ? path : "/\(path)"

        // Merge uniqueId with provided parameters.
        // Caller-supplied "uniqueId" overrides the client's default if present.
        var merged = ["uniqueId": uniqueId]
        for (k, v) in queryParameters {
            merged[k] = v
        }

        components.queryItems = merged.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    // Async GET that returns response body as String (UTF-8)
    func get(path: String, queryParameters: [String: String] = [:]) async throws -> String {
        guard let url = buildURL(path: path, queryParameters: queryParameters) else {
            throw NSError(
                domain: "ClientCertHTTPClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to construct URL"])
        }

        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse {
            print("HTTP status: \(http.statusCode)")
        }

        guard let body = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "ClientCertHTTPClient", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No data or UTF-8 decode failed"])
        }

        return body
    }

    // Fetch and parse app list from the API
    func getAppList() async throws -> AppList {
        guard let url = buildURL(path: "/applist", queryParameters: [:]) else {
            throw NSError(
                domain: "ClientCertHTTPClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to construct URL"])
        }

        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse {
            print("HTTP status: \(http.statusCode)")
        }

        // // Log raw XML response
        // if let xmlString = String(data: data, encoding: .utf8) {
        //     print("Raw XML response:")
        //     print(xmlString)
        // }

        let decoder = XMLDecoder()
        return try decoder.decode(AppList.self, from: data)
    }

    // Launch an app and return encryption keys and session URL
    func launchApp(appId: UInt64) async throws -> LaunchAppInfo {
        let aesKey = generateRandomBytes(count: 16)
        let aesIV = generateRandomBytes(count: 16)
        let aesKeyHex = aesKey.map { String(format: "%02x", $0) }.joined()
        let aesIVHex = aesIV.map { String(format: "%02x", $0) }.joined()

        let queryParams: [String: String] = [
            "appid": String(appId),
            "mode": "2560x1440x60",
            "additionalStates": "1",
            "sops": "0",
            "localAudioPlayMode": "0",
            "corever": "1",
            "rikey": aesKeyHex,
            "rikeyid": aesIVHex,
        ]

        guard let url = buildURL(path: "/launch", queryParameters: queryParams) else {
            throw NSError(
                domain: "ClientCertHTTPClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to construct URL"])
        }

        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse {
            print("HTTP status: \(http.statusCode)")
        }

        let decoder = XMLDecoder()
        let launchResponse = try decoder.decode(LaunchAppResponse.self, from: data)

        return LaunchAppInfo(
            aesKey: aesKey,
            aesIV: aesIV,
            sessionUrl: launchResponse.sessionUrl0
        )
    }

    // Fetch and parse server info from the API
    func getServerInfo() async throws -> ServerInfo {
        guard let url = buildURL(path: "/serverinfo", queryParameters: [:]) else {
            throw NSError(
                domain: "ClientCertHTTPClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to construct URL"])
        }

        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse {
            print("HTTP status: \(http.statusCode)")
        }

        let decoder = XMLDecoder()
        return try decoder.decode(ServerInfo.self, from: data)
    }

}

// Helper function to generate random bytes
private func generateRandomBytes(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return Data(bytes)
}
