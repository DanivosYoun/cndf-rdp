FROM danielguerra/ubuntu-xrdp@sha256:1a00da32f4e486f2f5fd8f656fc23bb235987c219153a587894469cad300b12d
RUN apt-get update && apt-get install -y --no-install-recommends xclip \
 && rm -rf /var/lib/apt/lists/*
COPY fixture.py /opt/harness-fixture.py
