//! Legacy TLS (1.0-1.2) upgrade through vendored OpenSSL 3 (design D-L1).
//!
//! Used only after the modern connection is rejected by TLS protocol version. OpenSSL does not
//! judge the certificate: the chain the server sent goes through the same webpki verifier and
//! chain callback as the rustls path before the stream is handed back to the connector.
use ironrdp_client::config::{TlsUpgradeIo, TlsUpgradeOutput, TlsUpgrader};
use openssl::ssl::{
    Ssl, SslContextBuilder, SslMethod, SslOptions, SslSessionCacheMode, SslVerifyMode, SslVersion,
};
use std::future::Future;
use std::io;
use std::pin::Pin;

use crate::engine::TLS_LOG_TARGET;

const CIPHERS: &str = "DEFAULT@SECLEVEL=0:!RC4:!3DES:!aNULL:!eNULL:!EXPORT:!MD5";

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
    builder.set_options(SslOptions::NO_TICKET);
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
            // Judge before returning: the connector sends CredSSP right after this future ends.
            let der: Vec<&[u8]> = chain.iter().map(Vec::as_slice).collect();
            ironrdp_tls::verify_certificate_chain(&der, &server_name, &endpoint, callback)?;
            tracing::info!(
                target: TLS_LOG_TARGET,
                "RDP tls profile=legacy version={} cipher={} engine=ironrdp",
                negotiated.version.as_deref().unwrap_or("unknown"),
                negotiated.cipher_suite.as_deref().unwrap_or("unknown"),
            );
            if negotiated.version.as_deref() == Some("TLSv1.2") {
                tracing::info!(target: TLS_LOG_TARGET, "RDP legacy TLS may be unnecessary for this server");
            }
            Ok((Box::new(stream) as Box<dyn TlsUpgradeIo>, chain, negotiated))
        })
    }
}

#[cfg(test)]
mod tests {
    use openssl::ssl::SslVersion;

    #[test]
    fn context_offers_tls_1_0_to_1_2() {
        let mut context = super::context().expect("legacy TLS context");
        assert_eq!(context.min_proto_version(), Some(SslVersion::TLS1));
        assert_eq!(context.max_proto_version(), Some(SslVersion::TLS1_2));
    }
}
