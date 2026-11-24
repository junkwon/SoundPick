import Foundation
import Security

/// Exports the root certificates macOS trusts to a PEM file, so yt-dlp
/// (which otherwise only trusts its own bundled certifi list) accepts the
/// same TLS connections as Safari — including networks that use an
/// organisation's TLS-inspection CA installed in the System keychain.
enum SystemCertificates {
    /// Builds (once per launch) and returns the PEM bundle path, or nil on failure.
    static func bundle() async -> URL? {
        await Builder.shared.path()
    }

    private actor Builder {
        static let shared = Builder()
        private var task: Task<URL?, Never>?

        func path() async -> URL? {
            if task == nil {
                task = Task.detached(priority: .userInitiated) { SystemCertificates.writeBundle() }
            }
            return await task!.value
        }
    }

    static func writeBundle() -> URL? {
        let certs = trustedRoots()
        guard !certs.isEmpty else { return nil }

        var pem = ""
        for cert in certs {
            let der = SecCertificateCopyData(cert) as Data
            let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            pem += "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
        }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PullTube", isDirectory: true)
        let file = dir.appendingPathComponent("system-ca-bundle.pem")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try pem.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    /// Apple's built-in roots plus any self-signed CA in the user's keychains
    /// (login, System) that macOS currently evaluates as trusted.
    static func trustedRoots() -> [SecCertificate] {
        var result: [SecCertificate] = []
        var seen = Set<Data>()

        func add(_ cert: SecCertificate) {
            let der = SecCertificateCopyData(cert) as Data
            if seen.insert(der).inserted { result.append(cert) }
        }

        var anchors: CFArray?
        if SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess,
           let anchors = anchors as? [SecCertificate] {
            anchors.forEach(add)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var items: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
           let keychainCerts = items as? [SecCertificate] {
            for cert in keychainCerts where isSelfIssued(cert) && isTrusted(cert) {
                add(cert)
            }
        }
        return result
    }

    private static func isSelfIssued(_ cert: SecCertificate) -> Bool {
        guard let subject = SecCertificateCopyNormalizedSubjectSequence(cert) as Data?,
              let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) as Data? else { return false }
        return subject == issuer
    }

    private static func isTrusted(_ cert: SecCertificate) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }
}
