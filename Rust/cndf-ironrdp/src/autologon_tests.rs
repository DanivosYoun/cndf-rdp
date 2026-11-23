//! Client Info logon decision (design iron-autologon-log, verification 1, patch 0033).
//!
//! The connector tests encode Client Info with the pinned upstream encoder. The peer tests run
//! the engine through the ABI against a local TLS peer that decrypts what the client sends and
//! decodes its Client Info. The password is a synthetic test value.

use super::*;
use ironrdp_client::config::{ConfigBuilder, Destination};
use ironrdp_connector::{ClientConnector, ClientConnectorState, Sequence as _};
use ironrdp_core::{decode, encode_vec, WriteBuf};
use ironrdp_pdu::mcs;
use ironrdp_pdu::nego::{self, SecurityProtocol};
use ironrdp_pdu::rdp::client_info::{ClientInfo, ClientInfoFlags};
use ironrdp_pdu::rdp::ClientInfoPdu;
use ironrdp_pdu::x224::{X224Data, X224};
use std::ffi::{c_void, CString};
use std::sync::atomic::AtomicUsize;
use tokio::io::{AsyncRead, AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _};

/// Synthetic; the surrounding spaces must reach Client Info unchanged.
const PASSWORD: &str = " cndf-synthetic-Pw-7f3a ";
const USERNAME: &str = "cndf-user";

// ---- connector: the pinned Client Info encoder -----------------------------------------------

fn connector_config(username: &str, password: &str) -> ironrdp_connector::Config {
    ConfigBuilder::new()
        .with_destination(Destination::from_parts("localhost", 3389))
        .with_client_build(420)
        .with_client_dir("")
        .with_platform(ironrdp_pdu::rdp::capability_sets::MajorPlatformType::OSX)
        .with_client_name("test")
        .with_username(username)
        .with_password(password)
        .with_autologon(!username.is_empty() && !password.is_empty())
        .build()
        .unwrap()
        .connector()
        .clone()
}

/// Encodes the Client Info a connector sends after the security upgrade `selected`.
/// `policy` is the patch 0033 eligibility (None: upstream behavior), `confirm` whether the TLS
/// upgrade succeeded. Returns what confirm reported and the decoded Client Info.
fn encoded_client_info(
    config: ironrdp_connector::Config,
    policy: Option<bool>,
    selected: SecurityProtocol,
    confirm: bool,
) -> (bool, ClientInfo) {
    let mut connector = ClientConnector::new(config, "127.0.0.1:3389".parse().unwrap());
    if let Some(eligible) = policy {
        connector = connector.with_tls_only_autologon(eligible);
    }
    connector.state = ClientConnectorState::EnhancedSecurityUpgrade {
        selected_protocol: selected,
    };
    let confirmed = confirm && connector.confirm_tls_only_autologon();
    connector.state = ClientConnectorState::SecureSettingsExchange {
        io_channel_id: 1003,
        user_channel_id: 1007,
    };
    let mut output = WriteBuf::new();
    connector.step(&[], None, &mut output).unwrap();
    let request = decode::<X224<mcs::SendDataRequest<'_>>>(output.filled())
        .unwrap()
        .0;
    let pdu = decode::<ClientInfoPdu>(request.user_data.as_ref()).unwrap();
    (confirmed, pdu.client_info)
}

fn logs_on(info: &ClientInfo) -> (bool, &str) {
    (
        info.flags.contains(ClientInfoFlags::AUTOLOGON),
        info.credentials.password.as_str(),
    )
}

#[test]
fn client_info_sends_the_flag_and_the_password_together_only_on_confirmed_tls() {
    let config = || connector_config(USERNAME, PASSWORD);
    let ssl = SecurityProtocol::SSL;
    let cases = [
        // (case, config, policy, selected, confirm, expected confirm, expected logon)
        ("tls confirmed", config(), Some(true), ssl, true, true, (true, PASSWORD)),
        ("tls before confirm", config(), Some(true), ssl, false, false, (false, "")),
        ("nla", config(), Some(true), SecurityProtocol::HYBRID, true, false, (false, "")),
        ("nla ex", config(), Some(true), SecurityProtocol::HYBRID_EX, true, false, (false, "")),
        ("redirection target", config(), Some(false), ssl, true, false, (false, "")),
        ("empty password", connector_config(USERNAME, ""), Some(true), ssl, true, false, (false, "")),
        ("no username", connector_config("", PASSWORD), Some(true), ssl, true, false, (false, "")),
    ];
    for (case, config, policy, selected, confirm, expected_confirm, expected) in cases {
        let (confirmed, info) = encoded_client_info(config, policy, selected, confirm);
        assert_eq!(confirmed, expected_confirm, "{case}");
        assert_eq!(logs_on(&info), expected, "{case}");
        assert_eq!(info.credentials.username, if case == "no username" { "" } else { USERNAME }, "{case}");
    }
}

#[test]
fn connectors_without_the_policy_keep_the_upstream_client_info() {
    // Other upstream callers: the password is always sent and Config::autologon sets the flag.
    let (confirmed, info) =
        encoded_client_info(connector_config(USERNAME, PASSWORD), None, SecurityProtocol::HYBRID, true);
    assert!(!confirmed);
    assert_eq!(logs_on(&info), (true, PASSWORD));
}

// ---- engine against a local TLS peer --------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum PeerTls {
    /// rustls, TLS 1.2 and 1.3: the engine's modern handshake.
    Modern,
    /// OpenSSL limited to TLS 1.1: the modern handshake fails and the engine retries legacy TLS.
    #[cfg(feature = "legacy-tls")]
    Legacy,
}

/// What the peer received over all connections.
#[derive(Default, Debug)]
struct Capture {
    tls_handshakes: usize,
    client_infos: Vec<ClientInfo>,
    /// Everything the client sent after its TLS handshake, decrypted.
    plaintext: Vec<u8>,
}

const PEER_CERT: &[u8] = include_bytes!("../tests/data/tls/peer-cert.der");
const PEER_KEY: &[u8] = include_bytes!("../tests/data/tls/peer-key.der");

trait PeerStream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> PeerStream for T {}

/// A peer on 127.0.0.1 for up to `connections` connections: X.224 selecting TLS-only security,
/// TLS, MCS connect and channel joins, then it reads Client Info and closes the connection.
fn spawn_peer(tls: PeerTls, connections: usize) -> (u16, thread::JoinHandle<Capture>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    listener.set_nonblocking(true).unwrap();
    let thread = thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let listener = tokio::net::TcpListener::from_std(listener).unwrap();
            let mut capture = Capture::default();
            for _ in 0..connections {
                let Ok(Ok((stream, _))) =
                    tokio::time::timeout(Duration::from_secs(10), listener.accept()).await
                else {
                    break;
                };
                let _ = tokio::time::timeout(
                    Duration::from_secs(10),
                    serve(stream, tls, &mut capture),
                )
                .await;
            }
            capture
        })
    });
    (port, thread)
}

async fn read_tpkt<S: AsyncRead + Unpin>(stream: &mut S) -> std::io::Result<Vec<u8>> {
    let mut frame = vec![0; 4];
    stream.read_exact(&mut frame).await?;
    let length = usize::from(u16::from_be_bytes([frame[2], frame[3]]));
    if frame[0] != 3 || length < 4 {
        return Err(std::io::Error::other("not a TPKT frame"));
    }
    frame.resize(length, 0);
    stream.read_exact(&mut frame[4..]).await?;
    Ok(frame)
}

fn bytes<T: ironrdp_core::Encode>(pdu: &T) -> Vec<u8> {
    encode_vec(pdu).unwrap()
}

async fn tls_accept(
    tcp: tokio::net::TcpStream,
    tls: PeerTls,
) -> std::io::Result<Box<dyn PeerStream>> {
    match tls {
        PeerTls::Modern => {
            let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
            let config = rustls::ServerConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .map_err(std::io::Error::other)?
                .with_no_client_auth()
                .with_single_cert(
                    vec![rustls::pki_types::CertificateDer::from(PEER_CERT.to_vec())],
                    rustls::pki_types::PrivateKeyDer::Pkcs8(PEER_KEY.to_vec().into()),
                )
                .map_err(std::io::Error::other)?;
            let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
            Ok(Box::new(acceptor.accept(tcp).await?))
        }
        #[cfg(feature = "legacy-tls")]
        PeerTls::Legacy => {
            use openssl::ssl::{Ssl, SslContextBuilder, SslMethod, SslVersion};
            let context = (|| {
                let mut builder = SslContextBuilder::new(SslMethod::tls_server())?;
                builder.set_min_proto_version(Some(SslVersion::TLS1_1))?;
                builder.set_max_proto_version(Some(SslVersion::TLS1_1))?;
                builder.set_cipher_list("DEFAULT@SECLEVEL=0")?;
                builder.set_security_level(0);
                let certificate = openssl::x509::X509::from_der(PEER_CERT)?;
                let key = openssl::pkey::PKey::private_key_from_der(PEER_KEY)?;
                builder.set_certificate(&certificate)?;
                builder.set_private_key(&key)?;
                Ok::<_, openssl::error::ErrorStack>(builder.build())
            })()
            .map_err(std::io::Error::other)?;
            let ssl = Ssl::new(&context).map_err(std::io::Error::other)?;
            let mut stream = tokio_openssl::SslStream::new(ssl, tcp).map_err(std::io::Error::other)?;
            std::pin::Pin::new(&mut stream)
                .accept()
                .await
                .map_err(std::io::Error::other)?;
            Ok(Box::new(stream))
        }
    }
}

async fn serve(
    mut tcp: tokio::net::TcpStream,
    tls: PeerTls,
    capture: &mut Capture,
) -> std::io::Result<()> {
    let request = read_tpkt(&mut tcp).await?;
    decode::<X224<nego::ConnectionRequest>>(&request).map_err(std::io::Error::other)?;
    let confirm = nego::ConnectionConfirm::Response {
        flags: nego::ResponseFlags::EXTENDED_CLIENT_DATA_SUPPORTED,
        protocol: SecurityProtocol::SSL,
    };
    tcp.write_all(&bytes(&X224(confirm))).await?;
    let mut stream = tls_accept(tcp, tls).await?;
    capture.tls_handshakes += 1;

    const IO_CHANNEL: u16 = 1003;
    const USER_CHANNEL: u16 = 1007;
    let next = async |stream: &mut Box<dyn PeerStream>, capture: &mut Capture| {
        let frame = read_tpkt(stream).await?;
        capture.plaintext.extend_from_slice(&frame);
        Ok::<_, std::io::Error>(frame)
    };
    let frame = next(&mut stream, capture).await?;
    let data = decode::<X224<X224Data<'_>>>(&frame).map_err(std::io::Error::other)?.0;
    let initial = decode::<mcs::ConnectInitial>(data.data.as_ref()).map_err(std::io::Error::other)?;
    let blocks = initial.conference_create_request.into_gcc_blocks();
    let channels = blocks.network.map_or(0, |network| network.channels.len());
    let channel_ids = (1..=channels as u16).map(|i| IO_CHANNEL + i).collect();
    let response = mcs::ConnectResponse {
        conference_create_response: ironrdp_pdu::gcc::ConferenceCreateResponse::new(
            USER_CHANNEL,
            ironrdp_pdu::gcc::ServerGccBlocks {
                core: ironrdp_pdu::gcc::ServerCoreData {
                    version: ironrdp_pdu::gcc::RdpVersion::V5_PLUS,
                    optional_data: ironrdp_pdu::gcc::ServerCoreOptionalData {
                        client_requested_protocols: Some(SecurityProtocol::SSL),
                        early_capability_flags: None,
                    },
                },
                security: ironrdp_pdu::gcc::ServerSecurityData::no_security(),
                network: ironrdp_pdu::gcc::ServerNetworkData {
                    channel_ids,
                    io_channel: IO_CHANNEL,
                },
                message_channel: None,
                multi_transport_channel: None,
            },
        )
        .map_err(std::io::Error::other)?,
        called_connect_id: 1,
        domain_parameters: mcs::DomainParameters::target(),
    };
    let response = X224Data {
        data: std::borrow::Cow::Owned(bytes(&response)),
    };
    stream.write_all(&bytes(&X224(response))).await?;
    loop {
        let frame = next(&mut stream, capture).await?;
        match decode::<X224<mcs::McsMessage<'_>>>(&frame).map_err(std::io::Error::other)?.0 {
            mcs::McsMessage::ErectDomainRequest(_) => {}
            mcs::McsMessage::AttachUserRequest(_) => {
                let confirm = mcs::AttachUserConfirm {
                    result: 0,
                    initiator_id: USER_CHANNEL,
                };
                stream.write_all(&bytes(&X224(confirm))).await?;
            }
            mcs::McsMessage::ChannelJoinRequest(request) => {
                let confirm = mcs::ChannelJoinConfirm {
                    result: 0,
                    initiator_id: USER_CHANNEL,
                    requested_channel_id: request.channel_id,
                    channel_id: request.channel_id,
                };
                stream.write_all(&bytes(&X224(confirm))).await?;
            }
            mcs::McsMessage::SendDataRequest(request) => {
                let pdu = decode::<ClientInfoPdu>(request.user_data.as_ref())
                    .map_err(std::io::Error::other)?;
                capture.client_infos.push(pdu.client_info);
                // Closing here is a server that ends the connection without a notification.
                return Ok(());
            }
            _ => return Err(std::io::Error::other("unexpected MCS message")),
        }
    }
}

#[derive(Default)]
struct Probe {
    trust: AtomicBool,
    trust_calls: AtomicUsize,
    events: Mutex<Vec<String>>,
    logs: Mutex<Vec<String>>,
}

fn probe(context: *mut c_void) -> &'static Probe {
    unsafe { &*context.cast::<Probe>() }
}

extern "C" fn on_trust(_: u64, _: *const CNDFIronCertificateChain, context: *mut c_void) -> bool {
    let probe = probe(context);
    probe.trust_calls.fetch_add(1, Ordering::AcqRel);
    probe.trust.load(Ordering::Acquire)
}

extern "C" fn on_log(_: u64, _: CNDFIronLogLevel, bytes: *const u8, length: usize, context: *mut c_void) {
    let message = unsafe { std::slice::from_raw_parts(bytes, length) };
    lock(&probe(context).logs).push(String::from_utf8_lossy(message).into_owned());
}

extern "C" fn on_failure(
    generation: u64,
    kind: CNDFIronFailureKind,
    code: u32,
    stage: CNDFIronStage,
    _: *const u8,
    _: usize,
    context: *mut c_void,
) {
    lock(&probe(context).events).push(format!("{generation} failure {kind:?} 0x{code:08x} {stage:?}"));
}

extern "C" fn on_disconnect(generation: u64, kind: CNDFIronDisconnectKind, code: u32, context: *mut c_void) {
    lock(&probe(context).events).push(format!("{generation} disconnect {kind:?} 0x{code:08x}"));
}

/// Connects `session` once to the peer on `port` and waits for the generation to end.
fn connect_once(session: *mut CNDFIronSession, probe: &Probe, port: u16, password: &str) -> u64 {
    let host = CString::new("127.0.0.1").unwrap();
    let username = CString::new(USERNAME).unwrap();
    let options = CNDFIronConnectOptions {
        struct_size: std::mem::size_of::<CNDFIronConnectOptions>() as u32,
        host: host.as_ptr(),
        port,
        username: username.as_ptr(),
        domain: ptr::null(),
        desktop_width: 1024,
        desktop_height: 768,
        scale_percent: 100,
        color_depth: 32,
        graphics_pipeline: false,
        log_level: CNDFIronLogLevel::CNDF_IRON_LOG_TRACE,
        clipboard: false,
        drive_path: ptr::null(),
        drive_name: ptr::null(),
        audio_mode: CNDFIronAudioMode::CNDF_IRON_AUDIO_OFF,
        keyboard_layout: 0,
        keyboard_type: 4,
        keyboard_subtype: 0,
        keyboard_function_keys: 12,
    };
    let before = lock(&probe.events).len();
    let mut generation = 0;
    let status = unsafe {
        cndf_iron_connect(session, &options, password.as_ptr(), password.len(), &mut generation)
    };
    assert_eq!(status, CNDF_IRON_OK);
    let deadline = Instant::now() + Duration::from_secs(20);
    while lock(&probe.events).len() == before && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    assert!(lock(&probe.events).len() > before, "the generation did not end");
    // Let the session thread finish so the next connect does not see BUSY.
    let deadline = Instant::now() + Duration::from_secs(5);
    while unsafe { &*session }
        .state
        .lock()
        .unwrap()
        .run
        .as_ref()
        .is_some_and(|run| run.threads.iter().any(|thread| !thread.is_finished()))
        && Instant::now() < deadline
    {
        thread::sleep(Duration::from_millis(5));
    }
    generation
}

fn session(probe: &Probe) -> *mut CNDFIronSession {
    let callbacks = CNDFIronCallbacks {
        log: Some(on_log),
        certificate_trust: Some(on_trust),
        connected: None,
        failure: Some(on_failure),
        disconnect: Some(on_disconnect),
        frame: None,
        pointer: None,
        remote_text: None,
        remote_file_list: None,
        remote_file_contents: None,
        context: (probe as *const Probe).cast_mut().cast(),
    };
    unsafe { cndf_iron_session_create(&callbacks) }
}

fn utf16(text: &str) -> Vec<u8> {
    text.encode_utf16().flat_map(u16::to_le_bytes).collect()
}

fn occurrences(haystack: &[u8], needle: &[u8]) -> usize {
    haystack.windows(needle.len()).filter(|window| *window == needle).count()
}

fn leaks(lines: &[String], secret: &str) -> bool {
    lines.iter().any(|line| line.contains(secret) || line.contains(secret.trim()))
}

/// Runs the connections `(trust, password)` in order on one session against one peer.
fn run_peer(tls: PeerTls, connections: &[(bool, &str)], tcp_per_connection: usize) -> (Capture, Vec<String>, Vec<String>, usize) {
    let (port, peer) = spawn_peer(tls, connections.len() * tcp_per_connection);
    let probe = Box::new(Probe::default());
    let session = session(&probe);
    for &(trust, password) in connections {
        probe.trust.store(trust, Ordering::Release);
        connect_once(session, &probe, port, password);
    }
    unsafe { cndf_iron_session_destroy(session, 5000) };
    let capture = peer.join().unwrap();
    let events = lock(&probe.events).clone();
    let logs = lock(&probe.logs).clone();
    let trust_calls = probe.trust_calls.load(Ordering::Acquire);
    (capture, events, logs, trust_calls)
}

fn assert_tls_only_logon(tls: PeerTls, tcp_per_connection: usize) {
    // Same target: trusted twice (a reconnect recomputes the decision), then rejected.
    let (capture, events, logs, trust_calls) = run_peer(
        tls,
        &[(true, PASSWORD), (true, PASSWORD), (false, PASSWORD)],
        tcp_per_connection,
    );
    assert_eq!(trust_calls, 3, "{tls:?}");
    // rustls judges the chain inside the handshake; the legacy upgrader judges it right after
    // OpenSSL completes it, before the connector writes anything.
    if tls == PeerTls::Modern {
        assert_eq!(capture.tls_handshakes, 2, "the rejected handshake must not complete");
    }
    assert_eq!(capture.client_infos.len(), 2, "{tls:?}");
    for info in &capture.client_infos {
        assert_eq!(logs_on(info), (true, PASSWORD), "{tls:?}");
        assert_eq!(info.credentials.username, USERNAME);
    }
    // The password went out once per logon, and only inside Client Info.
    assert_eq!(occurrences(&capture.plaintext, &utf16(PASSWORD)), 2, "{tls:?}");
    // No connection reported an authentication failure: the peer closed without notification.
    assert!(events.iter().all(|event| !event.contains("AUTHENTICATION")), "{events:?}");
    assert!(events.iter().any(|event| event.starts_with("3 failure CNDF_IRON_FAILURE_CERTIFICATE")), "{events:?}");
    assert!(!leaks(&logs, PASSWORD), "password in a TRACE log line");
}

#[test]
fn tls_only_peer_receives_the_password_only_after_trust() {
    assert_tls_only_logon(PeerTls::Modern, 1);
}

#[cfg(feature = "legacy-tls")]
#[test]
fn legacy_tls_peer_receives_the_password_only_after_trust() {
    // Each connection is a refused modern handshake, then the legacy retry.
    assert_tls_only_logon(PeerTls::Legacy, 2);
}

#[test]
fn tls_only_peer_without_a_password_gets_neither() {
    let (capture, _, _, _) = run_peer(PeerTls::Modern, &[(true, "")], 1);
    assert_eq!(capture.client_infos.len(), 1);
    assert_eq!(logs_on(&capture.client_infos[0]), (false, ""));
}

#[test]
fn the_leak_check_finds_a_planted_password() {
    // Control for the log checks above.
    assert!(leaks(&[format!("planted {}", PASSWORD.trim())], PASSWORD));
    assert!(!leaks(&["Starting IronRDP connection".to_owned()], PASSWORD));
}

// Design iron-autologon-log: a reconnect is a new generation whose H.264 totals start empty.
#[test]
fn each_connect_starts_a_generation_with_its_own_h264_totals() {
    let port = {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    };
    let probe = Box::new(Probe::default());
    let session = session(&probe);
    let totals = || {
        let state = lock(&unsafe { &*session }.state);
        Arc::clone(&state.run.as_ref().unwrap().connection.h264)
    };
    connect_once(session, &probe, port, PASSWORD);
    let first = totals();
    connect_once(session, &probe, port, PASSWORD);
    let second = totals();
    assert!(!Arc::ptr_eq(&first, &second));
    // Each generation's own end sealed its totals, which never saw a decode.
    assert_eq!((first.seal(), second.seal()), (None, None));
    unsafe { cndf_iron_session_destroy(session, 5000) };
    assert!(lock(&probe.logs).iter().all(|line| !line.starts_with("H.264 summary")));
}
