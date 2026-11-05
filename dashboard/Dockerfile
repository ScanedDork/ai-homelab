# Homelab dashboard: Python standard library only, no pip installs.
# python:3.12-alpine is multi-arch (linux/arm64 for n8npi, linux/amd64 for CI).
FROM docker.io/library/python:3.12-alpine3.20

RUN addgroup -S -g 10001 dashboard && adduser -S -D -H -u 10001 -G dashboard dashboard
WORKDIR /app
COPY server.py ./
COPY static ./static

USER 10001:10001
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=4).status == 200 else 1)"]
ENTRYPOINT ["python", "/app/server.py"]
