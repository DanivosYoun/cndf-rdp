# B5: hostile RDP server (server-memory design K8). The crate in server/ is built inside the
# IronRDP workspace at the commit the cndf-ironrdp crate pins (unpatched: the server side of
# the attacks needs none of the fork's client patches). cargo-lock.patch only adds this
# crate's own entry to the workspace lock, so the build stays --locked.
FROM rust:1.94.1-bookworm AS build
ARG IRONRDP_COMMIT=293cb4bee90baddfd7b8ea08d2f46e31947a3888
RUN git init -q /src && cd /src \
 && git remote add origin https://github.com/Devolutions/IronRDP.git \
 && git fetch -q --depth 1 origin "${IRONRDP_COMMIT}" \
 && git checkout -q --detach FETCH_HEAD
WORKDIR /src
COPY server /src/crates/b5-hostile
COPY cargo-lock.patch /cargo-lock.patch
RUN git apply /cargo-lock.patch
RUN cargo build --locked --release -p b5-hostile && cp target/release/b5-hostile /b5-hostile

FROM debian:bookworm-slim
COPY --from=build /b5-hostile /usr/local/bin/b5-hostile
EXPOSE 3389
# Attack, sizes and the certificate come from the run command (Scripts/run-hostile-harness.sh).
ENTRYPOINT ["/usr/local/bin/b5-hostile", "--bind", "0.0.0.0:3389"]
