import Foundation

/// The certificate trust key both engines hand to `shouldTrustCertificateFingerprint`.
///
/// FreeRDP runs with `CertificateCallbackPreferPEM`, so the "fingerprint" it reports is the
/// PEM of the leaf followed by the PEM of every certificate in the peer chain, and OpenSSL's
/// client-side peer chain starts with the leaf again: a self-signed server yields
/// `[leaf, leaf]`, a server sending an intermediate yields `[leaf, leaf, intermediate]`.
/// Producing the same bytes from IronRDP's chain keeps stored trust valid across engines.
public enum RDPCertificateTrustString {
    /// `PEM(der[0])` followed by `PEM(der[i])` for every `i`, each in OpenSSL
    /// `PEM_write_bio_X509` form (64-column base64, LF line endings). Empty for an empty chain.
    public static func freeRDPCompatible(derChain: [Data]) -> String {
        guard let leaf = derChain.first else { return "" }
        return ([leaf] + derChain).map(pem).joined()
    }

    private static func pem(_ der: Data) -> String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
    }
}
