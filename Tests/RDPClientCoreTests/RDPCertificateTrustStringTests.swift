import Foundation
import XCTest
@testable import RDPClientCore

/// Golden values come from OpenSSL 3.5.5 `openssl x509 -outform PEM` (`PEM_write_bio_X509`),
/// the writer FreeRDP 3.33.1 uses for the trust string. Certificates: a throwaway P-256 chain
/// (root -> intermediate -> leaf) generated for this test only.
final class RDPCertificateTrustStringTests: XCTestCase {
    private let leafDER = Data(base64Encoded: "MIIBbzCCARWgAwIBAgIUQGHEllrhYFy6CE3fUy6DCDJ9hOYwCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKZ29sZGVuLWludDAeFw0yNjExMjAwMzMzNDNaFw0zNjExMTcwMzMzNDNaMBYxFDASBgNVBAMMC2dvbGRlbi1sZWFmMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEY1G+L4l+2hHBC1RDWg7NAcA8u9f6Dnrjo/j3ropa6bEE+97Sl6eW0mcq99ulqXN79PcAZCS3Voff99LEguA+eqNCMEAwHQYDVR0OBBYEFD2MdNHmeol1FJPuXzi6JdKwJ3/AMB8GA1UdIwQYMBaAFAX6xz+Fp5ycfwsmjq5TI8SmDKNUMAoGCCqGSM49BAMCA0gAMEUCIE80/zygQQP0El2N5jA0A4Aqc4ew5d1UtQbW96/kt0msAiEAtDxGYDVEbKSb3eiaz9ESJohtgzaft4dVfXhK5LrbGrQ=")!
    private let intermediateDER = Data(base64Encoded: "MIIBfzCCASagAwIBAgIUPByUk1NVy8l80i6+VjBBMFawQ0swCgYIKoZIzj0EAwIwFjEUMBIGA1UEAwwLZ29sZGVuLXJvb3QwHhcNMjYxMTIwMDMzMzQzWhcNMzYxMTE3MDMzMzQzWjAVMRMwEQYDVQQDDApnb2xkZW4taW50MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE3xFvGhCFUAri9FhnvswvKxF0XuvlxcXC2GYgEFl/j4eNuWR7Kd1kEDoBPfjIjTnVGGH/gaHe+Lj9y20lRuG1XKNTMFEwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUBfrHP4WnnJx/CyaOrlMjxKYMo1QwHwYDVR0jBBgwFoAUSfVbdvlcYOmG0dC/4Au+868dse0wCgYIKoZIzj0EAwIDRwAwRAIgIgDi3SMUUA+TrxLX3k/Y0+bpRgLVxTW0V5h6G18jV58CICnEQLvgI3v8k3Z8caGQgVThL3ybh+41ufwHBYgPcnlC")!

    private let leafPEM = """
-----BEGIN CERTIFICATE-----
MIIBbzCCARWgAwIBAgIUQGHEllrhYFy6CE3fUy6DCDJ9hOYwCgYIKoZIzj0EAwIw
FTETMBEGA1UEAwwKZ29sZGVuLWludDAeFw0yNjExMjAwMzMzNDNaFw0zNjExMTcw
MzMzNDNaMBYxFDASBgNVBAMMC2dvbGRlbi1sZWFmMFkwEwYHKoZIzj0CAQYIKoZI
zj0DAQcDQgAEY1G+L4l+2hHBC1RDWg7NAcA8u9f6Dnrjo/j3ropa6bEE+97Sl6eW
0mcq99ulqXN79PcAZCS3Voff99LEguA+eqNCMEAwHQYDVR0OBBYEFD2MdNHmeol1
FJPuXzi6JdKwJ3/AMB8GA1UdIwQYMBaAFAX6xz+Fp5ycfwsmjq5TI8SmDKNUMAoG
CCqGSM49BAMCA0gAMEUCIE80/zygQQP0El2N5jA0A4Aqc4ew5d1UtQbW96/kt0ms
AiEAtDxGYDVEbKSb3eiaz9ESJohtgzaft4dVfXhK5LrbGrQ=
-----END CERTIFICATE-----

"""

    private let intermediatePEM = """
-----BEGIN CERTIFICATE-----
MIIBfzCCASagAwIBAgIUPByUk1NVy8l80i6+VjBBMFawQ0swCgYIKoZIzj0EAwIw
FjEUMBIGA1UEAwwLZ29sZGVuLXJvb3QwHhcNMjYxMTIwMDMzMzQzWhcNMzYxMTE3
MDMzMzQzWjAVMRMwEQYDVQQDDApnb2xkZW4taW50MFkwEwYHKoZIzj0CAQYIKoZI
zj0DAQcDQgAE3xFvGhCFUAri9FhnvswvKxF0XuvlxcXC2GYgEFl/j4eNuWR7Kd1k
EDoBPfjIjTnVGGH/gaHe+Lj9y20lRuG1XKNTMFEwDwYDVR0TAQH/BAUwAwEB/zAd
BgNVHQ4EFgQUBfrHP4WnnJx/CyaOrlMjxKYMo1QwHwYDVR0jBBgwFoAUSfVbdvlc
YOmG0dC/4Au+868dse0wCgYIKoZIzj0EAwIDRwAwRAIgIgDi3SMUUA+TrxLX3k/Y
0+bpRgLVxTW0V5h6G18jV58CICnEQLvgI3v8k3Z8caGQgVThL3ybh+41ufwHBYgP
cnlC
-----END CERTIFICATE-----

"""

    func testSelfSignedChainRepeatsTheLeafLikeFreeRDP() {
        XCTAssertEqual(
            RDPCertificateTrustString.freeRDPCompatible(derChain: [leafDER]),
            leafPEM + leafPEM
        )
    }

    func testServerChainIsLeafThenTheWholeChainInServerOrder() {
        XCTAssertEqual(
            RDPCertificateTrustString.freeRDPCompatible(derChain: [leafDER, intermediateDER]),
            leafPEM + leafPEM + intermediatePEM
        )
    }

    func testEmptyChainYieldsAnEmptyKey() {
        XCTAssertEqual(RDPCertificateTrustString.freeRDPCompatible(derChain: []), "")
    }
}
