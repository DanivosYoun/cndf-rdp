use crate::CNDFIronFailureKind::{self, *};
use crate::CNDFIronStage::{self, *};
use ironrdp_connector::{sspi::ErrorKind, ConnectorError, ConnectorErrorKind};
use ironrdp_pdu::desktop_framebuffer::DesktopFramebufferError;
use std::error::Error;

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Failure(
    pub CNDFIronFailureKind,
    pub u32,
    pub CNDFIronStage,
    pub &'static str,
);

pub(super) const PANIC: Failure = Failure(
    CNDF_IRON_FAILURE_ENGINE,
    0x49520001,
    CNDF_IRON_STAGE_UNKNOWN,
    "IronRDP worker panicked",
);
pub(super) const CONFIGURATION: Failure = Failure(
    CNDF_IRON_FAILURE_CONFIGURATION,
    0x49520003,
    CNDF_IRON_STAGE_INITIAL,
    "Invalid IronRDP connection configuration",
);

pub(super) const TLS_PROTOCOL_VERSION: u32 = 0x4952000B;

#[cfg(not(feature = "legacy-tls"))]
pub(super) const LEGACY_TLS_UNAVAILABLE: Failure = Failure(
    CNDF_IRON_FAILURE_TLS,
    0x4952000C,
    CNDF_IRON_STAGE_NEGOTIATION,
    "TLS protocol negotiation failed and legacy TLS is not available in this build",
);

pub(super) fn framebuffer_failure(error: DesktopFramebufferError, stage: CNDFIronStage) -> Failure {
    let (code, message) = match error {
        DesktopFramebufferError::Dimensions => (
            0x49520008,
            "Server desktop exceeds IronRDP framebuffer limits (8192 per edge, 67108864 pixels)",
        ),
        DesktopFramebufferError::Allocation => {
            (0x49520009, "IronRDP framebuffer allocation failed")
        }
    };
    Failure(CNDF_IRON_FAILURE_ENGINE, code, stage, message)
}

pub(super) fn framebuffer_cause(
    mut error: &(dyn Error + 'static),
) -> Option<DesktopFramebufferError> {
    loop {
        if let Some(error) = error.downcast_ref::<DesktopFramebufferError>() {
            return Some(*error);
        }
        error = error.source()?;
    }
}

fn logon_denied(status: Option<u32>, kind: ErrorKind) -> bool {
    match status {
        Some(status) => matches!(
            status,
            0xC0000064 | // STATUS_NO_SUCH_USER
            0xC000006A | // STATUS_WRONG_PASSWORD
            0xC000006D | // STATUS_LOGON_FAILURE
            0x8009030C // SEC_E_LOGON_DENIED
        ),
        None => kind == ErrorKind::LogonDenied,
    }
}

pub(super) fn classify(error: &ConnectorError, rejected: bool) -> Failure {
    if rejected {
        return Failure(
            CNDF_IRON_FAILURE_CERTIFICATE,
            0x49520002,
            CNDF_IRON_STAGE_NEGOTIATION,
            "Certificate rejected",
        );
    }
    if let Some(error) = framebuffer_cause(error) {
        return framebuffer_failure(error, CNDF_IRON_STAGE_CAPABILITIES);
    }
    let auth = match error.kind() {
        ConnectorErrorKind::AccessDenied => true,
        ConnectorErrorKind::Credssp(error) => logon_denied(
            error.nstatus.as_ref().map(|status| status.0),
            error.error_type,
        ),
        _ => false,
    };
    if auth {
        return Failure(
            CNDF_IRON_FAILURE_AUTHENTICATION,
            0x49520004,
            CNDF_IRON_STAGE_AUTHENTICATION,
            "CredSSP logon denied",
        );
    }

    // IronError exposes the pinned connector context through Display. It is used
    // only to select a fixed diagnostic and is never sent across the ABI.
    let context = error.to_string();
    if context.starts_with("[TCP connect]") {
        return Failure(
            CNDF_IRON_FAILURE_NETWORK,
            0x49520005,
            CNDF_IRON_STAGE_NEGOTIATION,
            "TCP connection failed",
        );
    }
    if context.starts_with("[TLS upgrade]") {
        let source = error
            .source()
            .and_then(|source| source.downcast_ref::<std::io::Error>())
            .and_then(|io| io.get_ref());
        #[cfg(feature = "legacy-tls")]
        if source.is_some_and(|source| {
            source.is::<openssl::ssl::Error>() || source.is::<openssl::error::ErrorStack>()
        }) {
            return Failure(
                CNDF_IRON_FAILURE_TLS,
                0x4952000D,
                CNDF_IRON_STAGE_NEGOTIATION,
                "Legacy OpenSSL TLS handshake failed",
            );
        }

        let tls = source.and_then(|source| source.downcast_ref::<rustls::Error>());
        let (code, message) = match tls {
            Some(rustls::Error::AlertReceived(rustls::AlertDescription::ProtocolVersion))
            | Some(rustls::Error::PeerIncompatible(
                rustls::PeerIncompatible::ServerDoesNotSupportTls12Or13,
            )) => (
                TLS_PROTOCOL_VERSION,
                "TLS protocol negotiation failed (servers below TLS 1.2 are unsupported)",
            ),
            _ => (0x49520006, "TLS handshake failed"),
        };
        return Failure(
            CNDF_IRON_FAILURE_TLS,
            code,
            CNDF_IRON_STAGE_NEGOTIATION,
            message,
        );
    }
    Failure(
        CNDF_IRON_FAILURE_ENGINE,
        0x49520007,
        CNDF_IRON_STAGE_NEGOTIATION,
        "IronRDP negotiation failed",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp_connector::sspi::{self, credssp::NStatusCode};

    #[test]
    fn classifies_only_allowlisted_credssp_logon_failures() {
        let generic = || ConnectorError::new("RDP", ConnectorErrorKind::General);
        let credssp = |status| {
            let mut sspi = sspi::Error::new(ErrorKind::InternalError, "secret sentinel");
            sspi.nstatus = Some(NStatusCode(status));
            ConnectorError::new("CredSSP", ConnectorErrorKind::Credssp(sspi))
        };
        let cases = [
            (generic(), true, CNDF_IRON_FAILURE_CERTIFICATE),
            (generic(), false, CNDF_IRON_FAILURE_ENGINE),
            (credssp(0xC000006A), false, CNDF_IRON_FAILURE_AUTHENTICATION),
            (credssp(0xC000006D), false, CNDF_IRON_FAILURE_AUTHENTICATION),
            (credssp(0xC0000022), false, CNDF_IRON_FAILURE_ENGINE),
            (
                ConnectorError::new("TCP connect", ConnectorErrorKind::General),
                false,
                CNDF_IRON_FAILURE_NETWORK,
            ),
        ];
        for (error, rejected, expected) in cases {
            let Failure(kind, _, _, description) = classify(&error, rejected);
            assert_eq!(kind, expected);
            assert!(!description.contains("secret sentinel"));
        }
    }

    #[cfg(feature = "legacy-tls")]
    #[test]
    fn classifies_openssl_tls_failure_separately() {
        let source = openssl::x509::X509::from_pem(b"invalid certificate").unwrap_err();
        assert!(!source.errors().is_empty());
        let error = ConnectorError::new("TLS upgrade", ConnectorErrorKind::General)
            .with_source(std::io::Error::other(source));
        assert_eq!(
            classify(&error, false),
            Failure(
                CNDF_IRON_FAILURE_TLS,
                0x4952000D,
                CNDF_IRON_STAGE_NEGOTIATION,
                "Legacy OpenSSL TLS handshake failed",
            ),
        );
    }

    #[test]
    fn distinguishes_tls_protocol_failures_from_other_handshake_failures() {
        let cases = [
            (
                rustls::Error::AlertReceived(rustls::AlertDescription::ProtocolVersion),
                0x4952000B,
                "TLS protocol negotiation failed (servers below TLS 1.2 are unsupported)",
            ),
            (
                rustls::Error::PeerIncompatible(
                    rustls::PeerIncompatible::ServerDoesNotSupportTls12Or13,
                ),
                0x4952000B,
                "TLS protocol negotiation failed (servers below TLS 1.2 are unsupported)",
            ),
            (
                rustls::Error::PeerIncompatible(
                    rustls::PeerIncompatible::NoCertificateRequestSignatureSchemesInCommon,
                ),
                0x49520006,
                "TLS handshake failed",
            ),
            (
                rustls::Error::AlertReceived(rustls::AlertDescription::HandshakeFailure),
                0x49520006,
                "TLS handshake failed",
            ),
        ];
        for (source, code, message) in cases {
            let error = ConnectorError::new("TLS upgrade", ConnectorErrorKind::General)
                .with_source(std::io::Error::other(source));
            assert_eq!(
                classify(&error, false),
                Failure(
                    CNDF_IRON_FAILURE_TLS,
                    code,
                    CNDF_IRON_STAGE_NEGOTIATION,
                    message,
                ),
            );
        }
    }
}
