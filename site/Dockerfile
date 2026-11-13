# The image of the blog at https://nedsi.io, built and pushed by
# .github/workflows/site-publish.yaml. COPY only, so the linux/arm64 image
# builds on an amd64 runner without emulation. public/ is the Hugo output.
FROM nginxinc/nginx-unprivileged:1.31.7-alpine3.24@sha256:b5047b9b76845eac124358373c6852377c52e4b05834a47647e955dd91cb8f1e
COPY nginx.conf /etc/nginx/nginx.conf
COPY public/ /usr/share/nginx/html/
