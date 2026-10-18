# ADR 007: Distroless Base Images

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to choose base images for production containers. Options:
1. **Distroless** - Minimal, no shell, no package manager (Google)
2. **Alpine** - Lightweight Linux with apk package manager
3. **Scratch** - Empty image, only binary
4. **Ubuntu/Debian slim** - Full OS with apt, minimal packages
5. **Chainguard** - Hardened, minimal images with signatures

## Decision

We will use **Distroless base images** for all production services.

### Images
| Language | Base Image | Size |
|----------|------------|------|
| Go | `gcr.io/distroless/static-debian12` | ~2MB |
| Node.js | `gcr.io/distroless/nodejs20-debian12` | ~80MB |
| Python | `gcr.io/distroless/python3-debian12` | ~40MB |

### Custom Platform Images
We also maintain custom base images with common tooling:
- `platform/go-base:1.22` - Go + certs + timezone
- `platform/node-base:20` - Node.js + dumb-init + certs

## Consequences

### Positive
- **Minimal attack surface** - No shell, no package manager, no unnecessary binaries
- **Small size** - Faster pulls, less disk usage
- **CVE reduction** - Fewer packages = fewer vulnerabilities
- **Reproducible** - Fixed base, deterministic builds
- **Compliance** - Meets security requirements (no shell = no shell exploits)

### Negative
- **No debugging tools** - No shell, curl, netcat, ps, lsof in production
- **No package installation** - Cannot `apt install` at runtime
- **Static linking required** - Go must be statically linked (CGO_ENABLED=0)
- **Learning curve** - Developers used to Alpine/Debian debugging
- **Certificates** - Must include ca-certificates in base

### Mitigation
- **Debug images** - Use `gcr.io/distroless/debug-*` variants for troubleshooting
- **Sidecar debugging** - Ephemeral debug containers with `kubectl debug`
- **Build-time tools** - All tooling in builder stage (multi-stage Dockerfile)
- **Health endpoints** - HTTP health checks instead of shell scripts
- **Structured logging** - JSON logs to stdout, no need for log rotation in container

## Dockerfile Pattern
```dockerfile
# Builder stage
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app/server .

# Production stage
FROM gcr.io/distroless/static-debian12
COPY --from=builder /app/server /server
USER 1000:1000
ENTRYPOINT ["/server"]
```

## Related
- ADR 008: Shared PostgreSQL Schemas