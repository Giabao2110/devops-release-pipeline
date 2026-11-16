# syntax=docker/dockerfile:1
# Multi-stage build: compile a static Go binary on the build platform, then copy
# it into a distroless "nonroot" image (no shell, no package manager, UID 65532).
ARG GO_VERSION=1.26

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VERSION=0.0.0-dev
ARG COMMIT=unknown
ARG BUILD_DATE=unknown
WORKDIR /src
COPY app/go.mod ./
COPY app/*.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath \
      -ldflags "-s -w -X main.version=${VERSION} -X main.commit=${COMMIT} -X main.buildDate=${BUILD_DATE}" \
      -o /out/release-demo .

FROM gcr.io/distroless/static-debian12:nonroot
ARG VERSION=0.0.0-dev
ARG COMMIT=unknown
LABEL org.opencontainers.image.title="release-demo" \
      org.opencontainers.image.source="https://github.com/Giabao2110/devops-release-pipeline" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.licenses="MIT"
COPY --from=build /out/release-demo /release-demo
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/release-demo"]
