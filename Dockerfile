# === Builder stage: Go-based tools ===
# Compiles Go-based tools (shfmt, tflint, terraform-docs, trivy, gitleaks)
FROM golang:1.25-bookworm AS go-builder

ARG TARGETARCH
ENV GOTOOLCHAIN=auto

# Install shfmt
RUN go install mvdan.cc/sh/v3/cmd/shfmt@latest

# Install tflint
RUN go install github.com/terraform-linters/tflint@latest

# Install terraform-docs
RUN go install github.com/terraform-docs/terraform-docs@latest

# Install gitleaks (pin version + inject via ldflags so `gitleaks version` reports correctly)
ARG GITLEAKS_VERSION=v8.30.0
RUN go install -ldflags "-X github.com/zricethezav/gitleaks/v8/version.Version=${GITLEAKS_VERSION}" \
    github.com/zricethezav/gitleaks/v8@${GITLEAKS_VERSION}

# Install golangci-lint v2
RUN go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest

# Install gofumpt
RUN go install mvdan.cc/gofumpt@latest

# Install govulncheck
RUN go install golang.org/x/vuln/cmd/govulncheck@latest

# === Rust builder stage ===
# Provides Rust toolchain (rustup + cargo + rustc + clippy + rustfmt) and
# installs cargo-audit and cargo-deny via cargo-binstall.
FROM rust:1-slim-bookworm AS rust-builder
RUN rustup component add clippy rustfmt
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN curl -L --proto '=https' --tlsv1.2 -sSf \
      https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
    | bash
RUN cargo binstall --no-confirm cargo-audit cargo-deny

# === Swift builder stage ===
# Provides Swift toolchain and builds swift-format from source
# (swift-format has no pre-built Linux binaries)
FROM swift:6.1-bookworm AS swift-builder
RUN git clone --depth 1 --branch 602.0.0 https://github.com/swiftlang/swift-format.git /tmp/swift-format \
    && cd /tmp/swift-format \
    && swift build -c release \
    && install -m 755 .build/release/swift-format /usr/local/bin/swift-format \
    && rm -rf /tmp/swift-format

# === JDK builder stage ===
# Provides JDK 21 for Kotlin tooling (ktlint, detekt, Gradle)
FROM eclipse-temurin:21-jdk AS jdk-builder

# === Node.js base: provides Node runtime for JS/TS tooling ===
FROM node:22-bookworm-slim AS node-base

# === Final stage ===
FROM debian:bookworm-slim AS runtime

ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/devrail-dev/dev-toolchain"
LABEL org.opencontainers.image.description="DevRail developer toolchain container"
LABEL org.opencontainers.image.licenses="MIT"

# Base system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    make \
    python3 \
    python3-pip \
    python3-venv \
    ruby \
    ruby-dev \
    build-essential \
    shellcheck \
    unzip \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install yq for YAML parsing in Makefile language detection
ARG YQ_VERSION=v4.44.1
RUN ARCH="$(dpkg --print-architecture)" && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
      -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Install git-cliff for changelog generation from conventional commits
ARG GIT_CLIFF_VERSION=2.12.0
RUN ARCH="$(uname -m)" && \
    curl -fsSL "https://github.com/orhun/git-cliff/releases/download/v${GIT_CLIFF_VERSION}/git-cliff-${GIT_CLIFF_VERSION}-${ARCH}-unknown-linux-gnu.tar.gz" \
      -o /tmp/git-cliff.tar.gz && \
    tar xzf /tmp/git-cliff.tar.gz -C /tmp && \
    mv /tmp/git-cliff-${GIT_CLIFF_VERSION}/git-cliff /usr/local/bin/git-cliff && \
    chmod +x /usr/local/bin/git-cliff && \
    rm -rf /tmp/git-cliff*

# Copy shared libraries
COPY lib/ /opt/devrail/lib/

# Copy install scripts
COPY scripts/ /opt/devrail/scripts/

# Copy default configuration files
COPY config/ /opt/devrail/config/

# Copy Node.js runtime from node-base (required for ESLint, Prettier, tsc, vitest)
COPY --from=node-base /usr/local/bin/node /usr/local/bin/node
COPY --from=node-base /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# Copy Rust toolchain from rust-builder (rustup + cargo + rustc + clippy + rustfmt + cargo-audit + cargo-deny)
COPY --from=rust-builder /usr/local/rustup /usr/local/rustup
COPY --from=rust-builder /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo

# Copy Swift toolchain from swift-builder (selective: binaries + runtime libs + swift-format)
COPY --from=swift-builder /usr/bin/swift /usr/bin/swiftc /usr/bin/swift-build /usr/bin/swift-test /usr/bin/swift-package /usr/bin/swift-run /usr/local/swift/bin/
COPY --from=swift-builder /usr/lib/swift /usr/local/swift/lib/swift
COPY --from=swift-builder /usr/lib/swift_static /usr/local/swift/lib/swift_static
COPY --from=swift-builder /usr/local/bin/swift-format /usr/local/bin/swift-format

# Copy JDK 21 from jdk-builder (required for Kotlin tooling: ktlint, detekt, Gradle)
COPY --from=jdk-builder /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk

# Set up environment (consolidated PATH — all language runtimes in one line)
ENV PATH="/opt/devrail/bin:/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/swift/bin:/opt/java/openjdk/bin:${PATH}"
ENV DEVRAIL_LIB="/opt/devrail/lib"

# Copy Go SDK from builder (required at runtime by golangci-lint, govulncheck)
COPY --from=go-builder /usr/local/go /usr/local/go

# Copy Go-built binaries from builder
COPY --from=go-builder /go/bin/shfmt /usr/local/bin/shfmt
COPY --from=go-builder /go/bin/tflint /usr/local/bin/tflint
COPY --from=go-builder /go/bin/terraform-docs /usr/local/bin/terraform-docs
COPY --from=go-builder /go/bin/gitleaks /usr/local/bin/gitleaks
COPY --from=go-builder /go/bin/golangci-lint /usr/local/bin/golangci-lint
COPY --from=go-builder /go/bin/gofumpt /usr/local/bin/gofumpt
COPY --from=go-builder /go/bin/govulncheck /usr/local/bin/govulncheck

# Run per-language install scripts
RUN bash /opt/devrail/scripts/install-python.sh
RUN bash /opt/devrail/scripts/install-bash.sh
RUN bash /opt/devrail/scripts/install-terraform.sh
RUN bash /opt/devrail/scripts/install-ansible.sh
RUN bash /opt/devrail/scripts/install-ruby.sh
RUN bash /opt/devrail/scripts/install-go.sh
RUN bash /opt/devrail/scripts/install-javascript.sh
RUN bash /opt/devrail/scripts/install-rust.sh
RUN bash /opt/devrail/scripts/install-swift.sh
RUN bash /opt/devrail/scripts/install-kotlin.sh
RUN bash /opt/devrail/scripts/install-universal.sh

# Allow git operations on mounted workspaces with different ownership
RUN git config --global --add safe.directory '*'

WORKDIR /workspace
