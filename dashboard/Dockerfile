# The image of homelab-dashboard, both roles (collect, web). Go
# cross-compiles, so linux/arm64 builds on an amd64 runner without emulation.
# The builder's Go version follows go.mod (scripts/ci/dashboard-check.sh).
FROM --platform=$BUILDPLATFORM golang:1.27.4-trixie@sha256:430985542100b871e108ccc00e8dcc5eef08ca14ee5825e98ebf563d8ffec4ee AS build
# LDFLAGS strips debug information by default; --build-arg LDFLAGS= keeps it.
ARG TARGETOS TARGETARCH VERSION=dev LDFLAGS="-s -w"
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "${LDFLAGS} -X main.version=${VERSION}" -o /out/homelab-dashboard ./cmd/homelab-dashboard

FROM gcr.io/distroless/static-debian13:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5
COPY --from=build /out/homelab-dashboard /homelab-dashboard
USER 65532:65532
ENTRYPOINT ["/homelab-dashboard"]
