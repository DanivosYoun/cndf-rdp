use crate::CNDFIronFailureKind::{self, *};
use crate::CNDFIronStage::{self, *};
use ironrdp_connector::{sspi::ErrorKind, ConnectorError, ConnectorErrorKind};
use ironrdp_pdu::desktop_framebuffer::DesktopFramebufferError;
use ironrdp_pdu::rdp::session_info::{
    LogonErrorNotificationData, LogonErrorNotificationDataErrorCode, LogonErrorNotificationType,
    LogonErrorsInfo,
};
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

#[cfg(feature = "legacy-tls")]
#[derive(Debug)]
struct RetryableHandshake {
    error: std::io::Error,
    reason: &'static str,
}

#[cfg(feature = "legacy-tls")]
impl std::fmt::Display for RetryableHandshake {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.error.fmt(f)
    }
}

#[cfg(feature = "legacy-tls")]
impl Error for RetryableHandshake {}

#[cfg(feature = "legacy-tls")]
pub(super) fn mark_legacy_retry(error: std::io::Error, received: usize) -> std::io::Error {
    use rustls::{AlertDescription, Error as TlsError, PeerIncompatible};
    use std::io::ErrorKind;

    let reason = match error
        .get_ref()
        .and_then(|source| source.downcast_ref::<TlsError>())
    {
        // This rustls error is raised while processing the initial ServerHello.
        Some(TlsError::PeerIncompatible(PeerIncompatible::ServerDoesNotSupportTls12Or13)) => {
            Some("ServerDoesNotSupportTls12Or13")
        }
        // A plaintext alert occupies one five-byte header and a two-byte payload.
        Some(TlsError::AlertReceived(alert)) if received == 7 => match alert {
            AlertDescription::ProtocolVersion => Some("ProtocolVersion"),
            AlertDescription::HandshakeFailure => Some("HandshakeFailure"),
            AlertDescription::InsufficientSecurity => Some("InsufficientSecurity"),
            _ => None,
        },
        // Win2019 can reset the connection without sending any TLS records.
        None if received == 0 => match error.kind() {
            ErrorKind::UnexpectedEof => Some("UnexpectedEof received=0"),
            ErrorKind::ConnectionReset => Some("ConnectionReset received=0"),
            ErrorKind::ConnectionAborted => Some("ConnectionAborted received=0"),
            _ => None,
        },
        _ => None,
    };
    match reason {
        Some(reason) => std::io::Error::new(error.kind(), RetryableHandshake { error, reason }),
        None => error,
    }
}

#[cfg(feature = "legacy-tls")]
pub(super) fn legacy_retry_reason(error: &ConnectorError, failure: &Failure) -> Option<&'static str> {
    if failure.0 != CNDF_IRON_FAILURE_TLS {
        return None;
    }
    error
        .source()
        .and_then(|source| source.downcast_ref::<std::io::Error>())
        .and_then(std::io::Error::get_ref)
        .and_then(|source| source.downcast_ref::<RetryableHandshake>())
        .map(|retry| retry.reason)
}

#[cfg(feature = "legacy-tls")]
impl Failure {
    pub(super) fn after_legacy_retry(mut self, legacy: Self) -> Self {
        match legacy.0 {
            CNDF_IRON_FAILURE_TLS => {
                self.3 = if self.1 == TLS_PROTOCOL_VERSION {
                    "TLS protocol negotiation failed. IronRDP legacy TLS connection failed."
                } else {
                    "TLS handshake failed. IronRDP legacy TLS connection failed."
                };
                self
            }
            _ => legacy,
        }
    }
}

#[cfg(not(feature = "legacy-tls"))]
pub(super) const LEGACY_TLS_UNAVAILABLE: Failure = Failure(
    CNDF_IRON_FAILURE_TLS,
    0x4952000C,
    CNDF_IRON_STAGE_NEGOTIATION,
    "TLS protocol negotiation failed and legacy TLS is not available in this build",
);

/// A server message over a client channel's size limit ended an active session.
pub(super) const CHANNEL_MESSAGE_LIMIT: Failure = Failure(
    CNDF_IRON_FAILURE_ENGINE,
    0x4952000E,
    CNDF_IRON_STAGE_ACTIVE,
    "서버가 보낸 채널 메시지가 크기 상한을 넘어 세션을 끝냈습니다",
);

/// A server rejected the credentials Client Info logged on with (TLS-only autologon).
pub(super) const LOGON_REJECTED: Failure = Failure(
    CNDF_IRON_FAILURE_AUTHENTICATION,
    0x4952000F,
    CNDF_IRON_STAGE_AUTHENTICATION,
    "Server logon rejected the credentials",
);

/// Whether a Logon Errors notification ([MS-RDPBCGR] 2.2.10.1.1.4.1.1) explicitly rejects the
/// credentials: a credential NTSTATUS, or `ERROR_CODE_ACCESS_DENIED` with
/// `LOGON_FAILED_BAD_PASSWORD`. A password change, a warning, a permission or session message
/// and any other status are not.
pub(super) fn rejects_logon(info: &LogonErrorsInfo) -> bool {
    use LogonErrorNotificationData::ErrorCode;
    use LogonErrorNotificationDataErrorCode::*;
    use LogonErrorNotificationType::*;
    match (info.error_type, &info.error_data) {
        (_, ErrorCode(FailedUpdatePassword | Warning)) => false,
        (NtStatus(status), _) => credential_status(status),
        (AccessDenied, ErrorCode(FailedBadPassword)) => true,
        _ => false,
    }
}

fn credential_status(status: u32) -> bool {
    matches!(
        status,
        0xC0000064 | // STATUS_NO_SUCH_USER
        0xC000006A | // STATUS_WRONG_PASSWORD
        0xC000006D // STATUS_LOGON_FAILURE
    )
}

/// The channel size limit that failed `error`, if one did.
pub(super) fn channel_limit_cause<'a>(
    mut error: &'a (dyn Error + 'static),
) -> Option<&'a ironrdp_svc::MessageSizeLimitExceeded> {
    loop {
        if let Some(cause) = error.downcast_ref::<ironrdp_svc::MessageSizeLimitExceeded>() {
            return Some(cause);
        }
        error = error.source()?;
    }
}

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
        let source = match source.and_then(|source| source.downcast_ref::<RetryableHandshake>()) {
            Some(retry) => retry.error.get_ref(),
            None => source,
        };
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

    #[test]
    fn only_explicit_credential_rejections_fail_the_logon() {
        use LogonErrorNotificationData::*;
        use LogonErrorNotificationDataErrorCode::*;
        use LogonErrorNotificationType::*;
        let cases = [
            (NtStatus(0xC000006D), ErrorCode(FailedBadPassword), true), // STATUS_LOGON_FAILURE
            (NtStatus(0xC000006A), ErrorCode(FailedOther), true), // STATUS_WRONG_PASSWORD
            (NtStatus(0xC0000064), ErrorCode(FailedBadPassword), true), // STATUS_NO_SUCH_USER
            (AccessDenied, ErrorCode(FailedBadPassword), true),
            // A password change, a warning, permission, session messages and other statuses.
            (NtStatus(0xC000006D), ErrorCode(FailedUpdatePassword), false),
            (NtStatus(0xC000006D), ErrorCode(Warning), false),
            (NtStatus(0xC0000224), ErrorCode(FailedBadPassword), false), // PASSWORD_MUST_CHANGE
            (NtStatus(0xC0000071), ErrorCode(FailedOther), false), // STATUS_PASSWORD_EXPIRED
            (NtStatus(0xC0000022), ErrorCode(FailedBadPassword), false), // STATUS_ACCESS_DENIED
            (AccessDenied, ErrorCode(FailedOther), false),
            (NoPermission, SessionId(0), false),
            (SessionContinue, SessionId(0), false),
            (DisconnectRefused, SessionId(3), false),
        ];
        for (error_type, error_data, expected) in cases {
            let info = LogonErrorsInfo {
                error_type,
                error_data: error_data.clone(),
            };
            assert_eq!(rejects_logon(&info), expected, "{error_type:?} {error_data:?}");
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

    #[cfg(feature = "legacy-tls")]
    #[test]
    fn retries_initial_version_and_security_alerts_only() {
        use rustls::{AlertDescription, Error as TlsError};
        for (alert, code) in [
            (AlertDescription::ProtocolVersion, TLS_PROTOCOL_VERSION),
            (AlertDescription::HandshakeFailure, 0x49520006),
            (AlertDescription::InsufficientSecurity, 0x49520006),
        ] {
            for received in [7, 128] {
                let source = std::io::Error::other(TlsError::AlertReceived(alert));
                let error = ConnectorError::new("TLS upgrade", ConnectorErrorKind::General)
                    .with_source(mark_legacy_retry(source, received));
                let failure = classify(&error, false);
                assert_eq!(failure.1, code);
                assert_eq!(legacy_retry_reason(&error, &failure).is_some(), received == 7);
                assert!(!legacy_retry_reason(&error, &classify(&error, true)).is_some());
            }
        }

        let source = std::io::Error::other(TlsError::PeerIncompatible(
            rustls::PeerIncompatible::ServerDoesNotSupportTls12Or13,
        ));
        let error = ConnectorError::new("TLS upgrade", ConnectorErrorKind::General)
            .with_source(mark_legacy_retry(source, 128));
        assert!(legacy_retry_reason(&error, &classify(&error, false)).is_some());

        let source = std::io::Error::other(TlsError::InvalidCertificate(
            rustls::CertificateError::UnknownIssuer,
        ));
        let error = ConnectorError::new("TLS upgrade", ConnectorErrorKind::General)
            .with_source(mark_legacy_retry(source, 128));
        assert!(!legacy_retry_reason(&error, &classify(&error, false)).is_some());
    }

    #[cfg(feature = "legacy-tls")]
    #[test]
    fn retries_transport_close_only_before_the_first_tls_record() {
        use std::io::ErrorKind::*;
        for (kind, received, retry) in [
            (UnexpectedEof, 0, true),
            (ConnectionReset, 0, true),
            (ConnectionAborted, 0, true),
            (ConnectionReset, 1, false),
            (UnexpectedEof, 128, false),
            (TimedOut, 0, false),
            (ConnectionRefused, 0, false),
            (Interrupted, 0, false),
        ] {
            let error = ConnectorError::new("TLS upgrade", ConnectorErrorKind::General)
                .with_source(mark_legacy_retry(kind.into(), received));
            let failure = classify(&error, false);
            assert_eq!(failure.1, 0x49520006);
            assert_eq!(legacy_retry_reason(&error, &failure).is_some(), retry, "{kind:?}");
        }
        for context in ["TCP connect", "Negotiate security", "CredSSP"] {
            let error = ConnectorError::new(context, ConnectorErrorKind::General)
                .with_source(std::io::Error::from(UnexpectedEof));
            assert!(!legacy_retry_reason(&error, &classify(&error, false)).is_some());
        }
    }

    #[cfg(feature = "legacy-tls")]
    #[test]
    fn preserves_initial_tls_code_only_if_legacy_tls_fails() {
        for source in [
            std::io::Error::from(std::io::ErrorKind::UnexpectedEof),
            std::io::Error::other(rustls::Error::AlertReceived(
                rustls::AlertDescription::ProtocolVersion,
            )),
        ] {
            let initial = ConnectorError::new("TLS upgrade", ConnectorErrorKind::General)
                .with_source(source);
            let retry_tls = ConnectorError::new("TLS upgrade", ConnectorErrorKind::General);
            let retry_tcp = ConnectorError::new("TCP connect", ConnectorErrorKind::General);
            let retry_auth = ConnectorError::new("CredSSP", ConnectorErrorKind::AccessDenied);
            let expected_code = classify(&initial, false).1;
            let failure = classify(&initial, false).after_legacy_retry(classify(&retry_tls, false));
            assert_eq!(failure.1, expected_code);
            assert!(failure.3.contains("IronRDP legacy TLS connection failed."));
            for (error, rejected) in [(&retry_tcp, false), (&retry_tls, true), (&retry_auth, false)] {
                let failure = classify(&initial, false).after_legacy_retry(classify(error, rejected));
                assert_eq!(failure, classify(error, rejected));
            }
        }
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
