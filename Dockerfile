FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libfreetype6 \
    libexpat1 \
    libpcap0.8 \
    libasound2 \
    libfontconfig1 \
    libgtk-3-0 \
    && rm -rf /var/lib/apt/lists/*

COPY target/release/sniffnet /usr/local/bin/sniffnet

ENTRYPOINT ["sniffnet"]
