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

# Install kustomize (Kubernetes manifest overlay tool)
RUN go install sigs.k8s.io/kustomize/kustomize/v5@latest

# Install kubeconform (Kubernetes manifest schema validation)
RUN go install github.com/yannh/kubeconform/cmd/kubeconform@latest

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
# Builds swift-format and SwiftLint from source (no pre-built arm64 Linux binaries)
FROM swift:6.1-bookworm AS swift-builder
RUN git clone --depth 1 --branch 602.0.0 https://github.com/swiftlang/swift-format.git /tmp/swift-format \
    && cd /tmp/swift-format \
    && swift build -c release \
    && install -m 755 .build/release/swift-format /usr/local/bin/swift-format \
    && rm -rf /tmp/swift-format
RUN git clone --depth 1 --branch 0.58.0 https://github.com/realm/SwiftLint.git /tmp/SwiftLint \
    && cd /tmp/SwiftLint \
    && swift build -c release \
    && install -m 755 .build/release/swiftlint /usr/local/bin/swiftlint \
    && rm -rf /tmp/SwiftLint

# === Ruby builder stage ===
# Provides Ruby 3.4 toolchain plus installed gems (rubocop, reek, brakeman,
# bundler-audit, rspec, sorbet). Debian bookworm ships Ruby 3.1 which cannot
# parse modern Rails 7+ Gemfiles (`platforms: %i[mri windows]`) — see #25.
FROM ruby:3.4-slim-bookworm AS ruby-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git \
    && rm -rf /var/lib/apt/lists/*
COPY lib/ /opt/devrail/lib/
COPY scripts/install-ruby.sh /opt/devrail/scripts/install-ruby.sh
RUN bash /opt/devrail/scripts/install-ruby.sh

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
    build-essential \
    libyaml-0-2 \
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
COPY --from=swift-builder /usr/local/bin/swiftlint /usr/local/bin/swiftlint

# Copy JDK 21 from jdk-builder (required for Kotlin tooling: ktlint, detekt, Gradle)
COPY --from=jdk-builder /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk

# Copy Ruby 3.4 toolchain + installed gems from ruby-builder.
# Mirrors the official ruby:3.4-slim-bookworm layout: binaries in /usr/local/bin,
# stdlib in /usr/local/lib/ruby, headers in /usr/local/include, and gems
# (rubocop, reek, brakeman, bundler-audit, rspec, sorbet) in /usr/local/bundle.
COPY --from=ruby-builder /usr/local/bin/ruby /usr/local/bin/ruby
COPY --from=ruby-builder /usr/local/bin/gem /usr/local/bin/gem
COPY --from=ruby-builder /usr/local/bin/bundle /usr/local/bin/bundle
COPY --from=ruby-builder /usr/local/bin/bundler /usr/local/bin/bundler
COPY --from=ruby-builder /usr/local/bin/irb /usr/local/bin/irb
COPY --from=ruby-builder /usr/local/bin/rake /usr/local/bin/rake
COPY --from=ruby-builder /usr/local/bin/erb /usr/local/bin/erb
COPY --from=ruby-builder /usr/local/bin/rdoc /usr/local/bin/rdoc
COPY --from=ruby-builder /usr/local/bin/ri /usr/local/bin/ri
COPY --from=ruby-builder /usr/local/bin/racc /usr/local/bin/racc
COPY --from=ruby-builder /usr/local/lib/ruby /usr/local/lib/ruby
COPY --from=ruby-builder /usr/local/lib/libruby.so.3.4 /usr/local/lib/libruby.so.3.4
COPY --from=ruby-builder /usr/local/include/ruby-3.4.0 /usr/local/include/ruby-3.4.0
COPY --from=ruby-builder /usr/local/bundle /usr/local/bundle
RUN ln -sf libruby.so.3.4 /usr/local/lib/libruby.so.3.4.0 \
    && ln -sf libruby.so.3.4 /usr/local/lib/libruby.so \
    && ldconfig
ENV GEM_HOME=/usr/local/bundle
ENV BUNDLE_PATH=/usr/local/bundle
ENV BUNDLE_SILENCE_ROOT_WARNING=1
ENV BUNDLE_APP_CONFIG=/usr/local/bundle

# Set up environment (consolidated PATH — all language runtimes in one line)
ENV PATH="/opt/devrail/bin:/usr/local/bundle/bin:/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/swift/bin:/opt/java/openjdk/bin:${PATH}"
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
COPY --from=go-builder /go/bin/kustomize /usr/local/bin/kustomize
COPY --from=go-builder /go/bin/kubeconform /usr/local/bin/kubeconform

# Run per-language install scripts
RUN bash /opt/devrail/scripts/install-python.sh
RUN bash /opt/devrail/scripts/install-bash.sh
RUN bash /opt/devrail/scripts/install-terraform.sh
RUN bash /opt/devrail/scripts/install-ansible.sh
# Ruby tooling is installed in the ruby-builder stage and COPY'd above
RUN bash /opt/devrail/scripts/install-go.sh
RUN bash /opt/devrail/scripts/install-javascript.sh
RUN bash /opt/devrail/scripts/install-rust.sh
RUN bash /opt/devrail/scripts/install-swift.sh
RUN bash /opt/devrail/scripts/install-kotlin.sh
RUN bash /opt/devrail/scripts/install-universal.sh

# Allow git operations on mounted workspaces with different ownership
RUN git config --global --add safe.directory '*'

WORKDIR /workspace
