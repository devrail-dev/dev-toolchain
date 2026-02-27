# === Builder stage: Go-based tools ===
# Compiles Go-based tools (shfmt, tflint, tfsec, terraform-docs, trivy, gitleaks)
FROM golang:1.24-bookworm AS go-builder

ARG TARGETARCH
ENV GOTOOLCHAIN=auto

# Install shfmt
RUN go install mvdan.cc/sh/v3/cmd/shfmt@latest

# Install tflint
RUN go install github.com/terraform-linters/tflint@latest

# Install tfsec
RUN go install github.com/aquasecurity/tfsec/cmd/tfsec@latest

# Install terraform-docs
RUN go install github.com/terraform-docs/terraform-docs@latest

# Install gitleaks
RUN go install github.com/zricethezav/gitleaks/v8@latest

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

# Copy shared libraries
COPY lib/ /opt/devrail/lib/

# Copy install scripts
COPY scripts/ /opt/devrail/scripts/

# Set up environment
ENV PATH="/opt/devrail/bin:/usr/local/go/bin:${PATH}"
ENV DEVRAIL_LIB="/opt/devrail/lib"

# Copy Go-built binaries from builder
COPY --from=go-builder /go/bin/shfmt /usr/local/bin/shfmt
COPY --from=go-builder /go/bin/tflint /usr/local/bin/tflint
COPY --from=go-builder /go/bin/tfsec /usr/local/bin/tfsec
COPY --from=go-builder /go/bin/terraform-docs /usr/local/bin/terraform-docs
COPY --from=go-builder /go/bin/gitleaks /usr/local/bin/gitleaks

# Run per-language install scripts
RUN bash /opt/devrail/scripts/install-python.sh
RUN bash /opt/devrail/scripts/install-bash.sh
RUN bash /opt/devrail/scripts/install-terraform.sh
RUN bash /opt/devrail/scripts/install-ansible.sh
RUN bash /opt/devrail/scripts/install-ruby.sh
RUN bash /opt/devrail/scripts/install-universal.sh

WORKDIR /workspace
