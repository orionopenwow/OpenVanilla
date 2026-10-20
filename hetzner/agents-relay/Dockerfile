# The Vanilla Agents relay (browser access, V-054). Standard library Python only; no packages installed.
FROM python:3.12-slim
WORKDIR /app
COPY varelay /app/varelay
ENV RELAY_HOST=0.0.0.0 RELAY_PORT=8790 RELAY_DATA=/data RELAY_TRUST_PROXY=1 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 65534:65534
EXPOSE 8790
CMD ["python", "-m", "varelay.relay"]
