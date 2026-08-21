# syntax=docker/dockerfile:1.7

# Base images pinned by digest for reproducible builds. Bump intentionally
# (e.g. for CVE patches) — never silently. To refresh:
#   docker pull <tag> && docker inspect --format='{{index .RepoDigests 0}}' <tag>
FROM golang:1.25-alpine@sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59 AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download # if only app code changes, this layer is cached

COPY . .

ARG VERSION=dev
ARG COMMIT=unknown
ARG BUILT_AT=unknown

# VERSION_PKG is the import path of the package whose vars receive build info.
ARG VERSION_PKG=github.com/AysuKeskin/kube-pulse/internal/version

RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w \
      -X ${VERSION_PKG}.Version=${VERSION} \
      -X ${VERSION_PKG}.Commit=${COMMIT} \
      -X ${VERSION_PKG}.BuiltAt=${BUILT_AT}" \
    -o /out/server ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot@sha256:d093aa3e30dbadd3efe1310db061a14da60299baff8450a17fe0ccc514a16639
WORKDIR /
COPY --from=build /out/server /server
USER nonroot:nonroot
EXPOSE 8080

# OCI labels for GHCR linkage and supply-chain provenance.
LABEL org.opencontainers.image.source="https://github.com/AysuKeskin/kube-pulse" \
      org.opencontainers.image.description="Small Go HTTP service with Kubernetes-ready probes and metrics" \
      org.opencontainers.image.licenses="MIT"

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD ["/server", "healthcheck"]

ENTRYPOINT ["/server"]
