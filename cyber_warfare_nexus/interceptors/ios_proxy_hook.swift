//
// =============================================================================
// HACKERAI IOS_PROXY_HOOK - SSL Pinning Bypass & Traffic Interceptor
// =============================================================================
// Texnikalar:
//   - Method swizzling (NSURLSession)
//   - Custom CA trust injection
//   - NSURLProtocol subclass for traffic interception
// =============================================================================
//

import Foundation
import UIKit

// ============================================================================
// HACKERAI PROXY ENGINE
// ============================================================================
@objc class HackeraiProxyEngine: NSObject {
    
    static let shared = HackeraiProxyEngine()
    private var capturedRequests = [CapturedRequest]()
    private let queue = DispatchQueue(label: "com.hackerai.proxy", attributes: .concurrent)
    
    // ============================================================================
    // SSL Pinning Bypass - Method Swizzling
    // ============================================================================
    
    /// ATS (App Transport Security) bypass
    @objc static func bypassATS() {
        let atsDict: [String: Any] = [
            "NSAllowsArbitraryLoads": true,
            "NSAllowsArbitraryLoadsInWebContent": true,
            "NSAllowsLocalNetworking": true,
            "NSExceptionDomains": [
                " ": ["NSIncludesSubdomains": true,
                     "NSTemporaryExceptionAllowsInsecureHTTPLoads": true,
                     "NSTemporaryExceptionMinimumTLSVersion": "TLSv1.0"]
            ]
        ]
        UserDefaults.standard.set(atsDict, forKey: "NSAppTransportSecurity")
    }
    
    // ============================================================================
    // NSURLProtocol - Custom protocol handler for traffic interception
    // ============================================================================
    
    class HackeraiURLProtocol: URLProtocol, URLSessionDelegate {
        
        override class func canInit(with request: URLRequest) -> Bool {
            guard let scheme = request.url?.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
        
        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }
        
        override func startLoading() {
            // Log the request
            HackeraiProxyEngine.shared.logRequest(request: request)
            
            var modifiedRequest = request
            modifiedRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
                                     forHTTPHeaderField: "User-Agent")
            
            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: modifiedRequest) { [weak self] data, response, error in
                guard let self = self else { return }
                if let error = error { self.client?.urlProtocol(self, didFailWithError: error); return }
                if let response = response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed) }
                if let data = data {
                    self.client?.urlProtocol(self, didLoad: data)
                    if let responseStr = String(data: data, encoding: .utf8) {
                        HackeraiProxyEngine.shared.analyzeResponse(responseStr, from: request.url?.host ?? "unknown")
                    }
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            task.resume()
        }
        
        override func stopLoading() { }
        
        // Accept all certificates
        func urlSession(_ session: URLSession, task: URLSessionTask,
                       didReceive challenge: URLAuthenticationChallenge,
                       completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                if let serverTrust = challenge.protectionSpace.serverTrust {
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
    
    // ============================================================================
    // REQUEST LOGGING & ANALYSIS
    // ============================================================================
    
    private func logRequest(request: URLRequest) {
        guard let url = request.url?.absoluteString else { return }
        let method = request.httpMethod ?? "GET"
        let headers = request.allHTTPHeaderFields ?? [:]
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        
        let entry = CapturedRequest(timestamp: Date(), method: method, url: url, headers: headers, body: body)
        
        queue.async(flags: .barrier) {
            self.capturedRequests.append(entry)
        }
        
        NSLog("[HACKERAI] \(method) \(url)")
    }
    
    private func analyzeResponse(_ response: String, from host: String) {
        let sensitivePatterns = [
            "access_token", "refresh_token", "session_id",
            "api_key", "apikey", "x-api-key", "authorization",
            "bearer", "jwt", "secret", "password"
        ]
        
        let lowercased = response.lowercased()
        for pattern in sensitivePatterns {
            if lowercased.contains(pattern) {
                NSLog("[HACKERAI][SENSITIVE] Found '\(pattern)' in response from \(host)")
                let snippet = String(response.prefix(500))
                queue.async(flags: .barrier) {
                    self.capturedRequests.append(
                        CapturedRequest(timestamp: Date(), method: "RESPONSE",
                                       url: "https://\(host)", headers: ["Content-Type": "application/json"],
                                       body: snippet)
                    )
                }
                break
            }
        }
    }
}

// ============================================================================
// DATA MODEL
// ============================================================================
struct CapturedRequest {
    let timestamp: Date
    let method: String
    let url: String
    let headers: [String: String]
    let body: String
}
