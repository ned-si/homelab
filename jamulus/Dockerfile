# The Jamulus server image (.kiro/specs/self-hosted-jamulus/design.md#image),
# built by .github/workflows/jamulus-publish.yaml from the upstream release's
# signed apt repository. Renovate updates JAMULUS_TAG (stable rX_Y_Z only).
FROM debian:bookworm-slim@sha256:e67eeead736ff7bbe258ef088bff683635c561b1fcfefad0806c1df4ab49ce0e
ARG JAMULUS_TAG=r3_12_6
COPY jamulus-release-key.asc /etc/apt/keyrings/jamulus.asc
# apt refuses the repository unless InRelease is signed by the committed key.
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    echo "deb [signed-by=/etc/apt/keyrings/jamulus.asc] https://github.com/jamulussoftware/jamulus/releases/download/${JAMULUS_TAG}/ ./" \
      > /etc/apt/sources.list.d/jamulus.list; \
    apt-get update; \
    version=$(echo "${JAMULUS_TAG#r}" | tr _ .); \
    apt-get install -y --no-install-recommends "jamulus-headless=${version}"; \
    rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 jamulus-ping /usr/local/bin/jamulus-ping
ENV HOME=/tmp
USER 65532:65532
EXPOSE 41124/udp
ENTRYPOINT ["/usr/bin/jamulus-headless"]
CMD ["--server", "--nogui", "--port", "41124"]
