//! Legacy TLS (1.0-1.2) upgrade through vendored OpenSSL 3 (design D-L1).
//!
//! Used only after an eligible early failure of the modern handshake. OpenSSL does not
//! judge the certificate: the chain the server sent goes through the same webpki verifier and
//! chain callback as the rustls path before the stream is handed back to the connector.
use ironrdp_client::config::{TlsUpgradeIo, TlsUpgradeOutput, TlsUpgrader};
use openssl::ssl::{
    Ssl, SslContextBuilder, SslMethod, SslOptions, SslSessionCacheMode, SslVerifyMode, SslVersion,
};
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use crate::engine::TLS_LOG_TARGET;

const CIPHERS: &str = "DEFAULT@SECLEVEL=0:!RC4:!3DES:!aNULL:!eNULL:!EXPORT:!MD5";

pub(super) struct ModernTlsUpgrader {
    pub(super) callback: ironrdp_tls::CertificateChainValidationCallback,
    pub(super) started: AtomicBool,
}

// Count incoming bytes during the handshake so a later EOF or alert cannot start a retry.
struct HandshakeIo {
    stream: Box<dyn TlsUpgradeIo>,
    received: Option<Arc<AtomicUsize>>,
}

impl AsyncRead for HandshakeIo {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buf.filled().len();
        let result = Pin::new(&mut self.stream).poll_read(cx, buf);
        if let Some(received) = &self.received {
            received.fetch_add(buf.filled().len() - before, Ordering::Relaxed);
        }
        result
    }
}

impl AsyncWrite for HandshakeIo {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.stream).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_shutdown(cx)
    }
}

impl TlsUpgrader for ModernTlsUpgrader {
    fn upgrade(
        &self,
        stream: Box<dyn TlsUpgradeIo>,
        server_name: String,
        endpoint: String,
    ) -> Pin<Box<dyn Future<Output = TlsUpgradeOutput> + Send>> {
        let callback = self.callback.clone();
        // Later upgrades (for example redirection) follow an earlier TLS handshake.
        let first = !self.started.swap(true, Ordering::Relaxed);
        Box::pin(async move {
            let received = Arc::new(AtomicUsize::new(0));
            let stream = HandshakeIo {
                stream,
                received: first.then(|| Arc::clone(&received)),
            };
            let (mut stream, _) = ironrdp_tls::upgrade_with_certificate_chain_validation_callback(
                stream,
                &server_name,
                &endpoint,
                callback,
            )
            .await
            .map_err(|error| {
                if first {
                    crate::errors::mark_legacy_retry(error, received.load(Ordering::Relaxed))
                } else {
                    error
                }
            })?;
            stream.get_mut().0.received = None;
            let chain = stream
                .get_ref()
                .1
                .peer_certificates()
                .ok_or_else(|| io::Error::other("peer certificate is missing"))?
                .iter()
                .map(|certificate| certificate.to_vec())
                .collect();
            let negotiated = ironrdp_tls::negotiated(&stream);
            let version = match negotiated.version.as_deref() {
                Some("TLSv1_2") => "TLSv1.2",
                Some("TLSv1_3") => "TLSv1.3",
                _ => "unknown",
            };
            tracing::info!(
                target: TLS_LOG_TARGET,
                "RDP tls profile=modern version={version} cipher={} engine=ironrdp",
                negotiated.cipher_suite.as_deref().unwrap_or("unknown"),
            );
            Ok((Box::new(stream) as Box<dyn TlsUpgradeIo>, chain, negotiated))
        })
    }
}

pub(super) struct LegacyTlsUpgrader {
    pub(super) callback: ironrdp_tls::CertificateChainValidationCallback,
}

fn context() -> Result<SslContextBuilder, openssl::error::ErrorStack> {
    let mut builder = SslContextBuilder::new(SslMethod::tls_client())?;
    builder.set_min_proto_version(Some(SslVersion::TLS1))?;
    builder.set_max_proto_version(Some(SslVersion::TLS1_2))?;
    builder.set_cipher_list(CIPHERS)?;
    builder.set_security_level(0);
    builder.set_verify(SslVerifyMode::NONE);
    builder.set_session_cache_mode(SslSessionCacheMode::OFF);
    // Windows Server 2019 CredSSP over TLS 1.0 needs the CBC empty fragment disabled.
    builder.set_options(SslOptions::NO_TICKET | SslOptions::DONT_INSERT_EMPTY_FRAGMENTS);
    Ok(builder)
}

impl TlsUpgrader for LegacyTlsUpgrader {
    fn upgrade(
        &self,
        stream: Box<dyn TlsUpgradeIo>,
        server_name: String,
        endpoint: String,
    ) -> Pin<Box<dyn Future<Output = TlsUpgradeOutput> + Send>> {
        let callback = self.callback.clone();
        Box::pin(async move {
            // No SNI (Ssl::new does not set a host name) and no session resumption.
            let context = context().map_err(io::Error::other)?.build();
            let ssl = Ssl::new(&context).map_err(io::Error::other)?;
            let mut stream =
                tokio_openssl::SslStream::new(ssl, stream).map_err(io::Error::other)?;
            Pin::new(&mut stream)
                .connect()
                .await
                .map_err(io::Error::other)?;
            let ssl = stream.ssl();
            // Client side: the chain as sent, leaf first (not the verified chain).
            let chain = ssl
                .peer_cert_chain()
                .ok_or_else(|| io::Error::other("the peer sent no certificate"))?
                .iter()
                .map(|certificate| certificate.to_der())
                .collect::<Result<Vec<_>, _>>()
                .map_err(io::Error::other)?;
            let negotiated = ironrdp_tls::NegotiatedTls {
                version: Some(ssl.version_str().to_owned()),
                cipher_suite: ssl.current_cipher().map(|cipher| cipher.name().to_owned()),
            };
            tracing::info!(
                target: TLS_LOG_TARGET,
                "RDP tls profile=legacy version={} cipher={} engine=ironrdp retry=true",
                negotiated.version.as_deref().unwrap_or("unknown"),
                negotiated.cipher_suite.as_deref().unwrap_or("unknown"),
            );
            // Judge before returning: the connector sends CredSSP right after this future ends.
            let der: Vec<&[u8]> = chain.iter().map(Vec::as_slice).collect();
            ironrdp_tls::verify_certificate_chain(&der, &server_name, &endpoint, callback)?;
            Ok((Box::new(stream) as Box<dyn TlsUpgradeIo>, chain, negotiated))
        })
    }
}

#[cfg(test)]
mod tests {
    use openssl::ssl::{SslContextBuilder, SslMethod, SslOptions, SslVersion};

    #[test]
    fn context_offers_tls_1_0_to_1_2() {
        let mut context = super::context().expect("legacy TLS context");
        assert_eq!(context.min_proto_version(), Some(SslVersion::TLS1));
        assert_eq!(context.max_proto_version(), Some(SslVersion::TLS1_2));
    }

    #[test]
    fn only_legacy_context_disables_empty_fragments() {
        let option = SslOptions::DONT_INSERT_EMPTY_FRAGMENTS;
        let default_context = SslContextBuilder::new(SslMethod::tls_client()).expect("TLS context");
        let legacy_context = super::context().expect("legacy TLS context");
        assert!(!default_context.options().contains(option));
        assert!(legacy_context.options().contains(option));
    }
}
