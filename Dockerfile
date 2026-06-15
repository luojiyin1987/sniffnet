FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    libfreetype6 \
    libexpat1 \
    libpcap0.8t64 \
    libasound2t64 \
    libfontconfig1 \
    libgtk-3-0t64 \
    && rm -rf /var/lib/apt/lists/*

COPY target/release/sniffnet /usr/local/bin/sniffnet

ENTRYPOINT ["sniffnet"]
