# The image of homelab-dashboard, both roles (collect, web). Go
# cross-compiles, so linux/arm64 builds on an amd64 runner without emulation.
# The builder's Go version follows go.mod (scripts/ci/dashboard-check.sh).
FROM --platform=$BUILDPLATFORM golang:1.27.4-trixie@sha256:f18c3d73a184fb0582828510722e723b63a93f7188d11dd223d9be6f6880e65d AS build
ARG TARGETOS TARGETARCH VERSION=dev
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/homelab-dashboard ./cmd/homelab-dashboard

FROM gcr.io/distroless/static-debian13:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931
COPY --from=build /out/homelab-dashboard /homelab-dashboard
USER 65532:65532
ENTRYPOINT ["/homelab-dashboard"]
