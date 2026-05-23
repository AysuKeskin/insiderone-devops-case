# syntax=docker/dockerfile:1.7

# Base images pinned by digest for reproducible builds. Bump intentionally
# (e.g. for CVE patches) — never silently. To refresh:
#   docker pull <tag> && docker inspect --format='{{index .RepoDigests 0}}' <tag>
FROM golang:1.25-alpine@sha256:8d22e29d960bc50cd025d93d5b7c7d220b1ee9aa7a239b3c8f55a57e987e8d45 AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG VERSION=dev
ARG COMMIT=unknown
ARG BUILT_AT=unknown

# VERSION_PKG is the import path of the package whose vars receive build info.
ARG VERSION_PKG=github.com/AysuKeskin/insiderone-devops-case/internal/version

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
LABEL org.opencontainers.image.source="https://github.com/AysuKeskin/insiderone-devops-case" \
      org.opencontainers.image.description="Tiny Go HTTP service for Insider One DevOps case study" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/server"]
