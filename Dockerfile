FROM rust:1.88-slim AS chef
RUN cargo install cargo-chef
WORKDIR /usr/src/sniffnet

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
RUN apt-get update && apt-get install -y \
    libfreetype6-dev \
    libexpat1-dev \
    libpcap-dev \
    libasound2-dev \
    libfontconfig1-dev \
    libgtk-3-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/sniffnet
COPY --from=planner /usr/src/sniffnet/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y \
    libfreetype6 \
    libexpat1 \
    libpcap0.8 \
    libasound2 \
    libfontconfig1 \
    libgtk-3-0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/src/sniffnet/target/release/sniffnet /usr/local/bin/sniffnet

ENTRYPOINT ["sniffnet"]
