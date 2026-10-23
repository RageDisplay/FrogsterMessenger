# syntax=docker/dockerfile:1

# One image for both binaries: frogsterd (API + WebSocket) and filed
# (attachments). The compose file picks which one a container runs.

FROM golang:1.26.10-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
        -o /out/bin/ ./cmd/frogsterd ./cmd/filed ./cmd/migrate \
    && mkdir -p /out/data/blobs

# distroless/static: no shell, no package manager, nothing to exploit beyond
# the binaries themselves. Runs as the image's unprivileged "nonroot" user.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/bin/ /usr/local/bin/
# Owned by nonroot so a named volume mounted here starts out writable.
COPY --from=build --chown=65532:65532 /out/data /var/lib/frogster

USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/frogsterd"]
