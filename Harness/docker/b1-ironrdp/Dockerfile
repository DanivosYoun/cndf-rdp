# B1: IronRDP examples/server (hybrid = TLS + CredSSP/NLA), pinned to the commit the
# cndf-ironrdp crate uses (design D1). Certificates are mounted at run time (/certs).
FROM rust:1.94.1-bookworm AS build
ARG IRONRDP_COMMIT=293cb4bee90baddfd7b8ea08d2f46e31947a3888
# libopus_sys (rdpsnd in the example) builds bundled opus with cmake.
RUN apt-get update && apt-get install -y --no-install-recommends cmake && rm -rf /var/lib/apt/lists/*
RUN git init -q /src && cd /src \
 && git remote add origin https://github.com/Devolutions/IronRDP.git \
 && git fetch -q --depth 1 origin "${IRONRDP_COMMIT}" \
 && git checkout -q --detach FETCH_HEAD
WORKDIR /src
COPY m3-channel-probe.patch /m3-channel-probe.patch
RUN git apply /m3-channel-probe.patch
RUN cargo build --locked --release -p ironrdp --example server \
      --features cliprdr,connector,core,dvc,pdu,rdpsnd,server \
 && cp target/release/examples/server /ironrdp-server

FROM debian:bookworm-slim
COPY --from=build /ironrdp-server /usr/local/bin/ironrdp-server
EXPOSE 3389
# Credentials and cert paths come from the run command (Scripts/run-engine-harness.sh).
ENTRYPOINT ["/usr/local/bin/ironrdp-server", "--bind-addr", "0.0.0.0:3389"]
