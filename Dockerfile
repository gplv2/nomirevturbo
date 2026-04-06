# Copyright 2026 Glenn Plas / Bitless BVBA
# SPDX-License-Identifier: Apache-2.0

# Stage 1: Build S2 geometry library + C++ indexer
FROM debian:trixie-slim AS builder-cpp

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build git ca-certificates \
    libosmium2-dev libprotozero-dev libabsl-dev libssl-dev \
    zlib1g-dev libbz2-dev libexpat1-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*

# Build s2geometry from source (no apt package on Trixie)
RUN git clone --depth 1 --branch v0.11.1 https://github.com/google/s2geometry.git /tmp/s2geometry \
    && cd /tmp/s2geometry \
    && cmake . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DBUILD_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build build -j$(nproc) \
    && cmake --install build \
    && ldconfig \
    && rm -rf /tmp/s2geometry

WORKDIR /src
COPY builder/ builder/
RUN mkdir build && cd build \
    && cmake ../builder -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc)

# Stage 2: Build Rust server
FROM rust:slim-bookworm AS builder-rust

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY server/ server/
RUN cargo build --release --manifest-path server/Cargo.toml

# Stage 3: Runtime
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libabsl20240722 \
    zlib1g libbz2-1.0 libexpat1 liblz4-1 \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy s2 shared library from builder
COPY --from=builder-cpp /usr/local/lib/libs2.so* /usr/local/lib/
RUN ldconfig

COPY --from=builder-cpp /src/build/build-index /usr/local/bin/
COPY --from=builder-rust /src/server/target/release/query-server /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["entrypoint.sh"]
CMD ["auto"]
