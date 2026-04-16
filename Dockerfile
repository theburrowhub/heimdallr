# ─── Stage 1: Build Heimdallr daemon ──────────────────────────────────────────
FROM golang:1.21-alpine AS builder

RUN apk add --no-cache git

WORKDIR /build
COPY daemon/go.mod daemon/go.sum ./
RUN go mod download

COPY daemon/ .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /heimdallr ./cmd/heimdallr

# ─── Stage 2: Runtime with AI CLIs ───────────────────────────────────────────
FROM node:20-alpine

RUN apk add --no-cache ca-certificates tzdata bash curl coreutils

# ── Install AI CLI tools ──────────────────────────────────────────────────────
# Claude Code CLI (Anthropic) — requires ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN at runtime
RUN npm install -g @anthropic-ai/claude-code 2>/dev/null || true

# Gemini CLI (Google) — requires GEMINI_API_KEY at runtime
RUN npm install -g @google/gemini-cli 2>/dev/null || true

# Codex CLI (OpenAI) — requires OPENAI_API_KEY or CODEX_API_KEY at runtime
RUN npm install -g @openai/codex 2>/dev/null || true

# OpenCode CLI — requires provider API key (e.g. ANTHROPIC_API_KEY) at runtime
# Install the musl-specific binary package alongside the main package (Alpine uses musl).
# Then symlink the musl binary into the wrapper's expected location.
RUN npm install -g opencode-ai opencode-linux-x64-musl 2>/dev/null || true \
    && MUSL_BIN="/usr/local/lib/node_modules/opencode-linux-x64-musl/bin/opencode" \
    && WRAPPER_BIN="/usr/local/lib/node_modules/opencode-ai/bin/.opencode" \
    && if [ -f "$MUSL_BIN" ]; then cp "$MUSL_BIN" "$WRAPPER_BIN" && chmod +x "$WRAPPER_BIN"; fi

# Clean npm cache to reduce image size
RUN npm cache clean --force 2>/dev/null || true

# ── Create non-root user ─────────────────────────────────────────────────────
RUN addgroup -S heimdallr && adduser -S heimdallr -G heimdallr

# ── Create directories ───────────────────────────────────────────────────────
# Heimdallr dirs
RUN mkdir -p /config /data && chown -R heimdallr:heimdallr /config /data

# AI CLI config/cache directories (must be writable by the runtime user)
RUN mkdir -p /home/heimdallr/.claude \
             /home/heimdallr/.gemini \
             /home/heimdallr/.codex \
             /home/heimdallr/.config/opencode \
             /home/heimdallr/.local/share/opencode \
    && chown -R heimdallr:heimdallr /home/heimdallr

# ── Copy Heimdallr binary ────────────────────────────────────────────────────
COPY --from=builder /heimdallr /usr/local/bin/heimdallr

# ── Default environment ──────────────────────────────────────────────────────
ENV HEIMDALLR_DATA_DIR=/data
ENV HEIMDALLR_CONFIG_PATH=/config/config.toml
ENV HEIMDALLR_BIND_ADDR=0.0.0.0
# Ensure npm global binaries are in PATH
ENV PATH="/usr/local/lib/node_modules/.bin:${PATH}"
# Disable interactive prompts / auto-updates in AI CLIs
ENV CI=true
ENV OPENCODE_DISABLE_AUTOUPDATE=true

EXPOSE 7842

VOLUME ["/data", "/config"]

USER heimdallr
WORKDIR /home/heimdallr

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:7842/health || exit 1

ENTRYPOINT ["/usr/local/bin/heimdallr"]
