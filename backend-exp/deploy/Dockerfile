# The dev backend as a container. The binary is cross-compiled outside
# (deploy.sh) and is the only file sent with this Dockerfile, so no .env or
# key can end up in the image.
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY everyai-backend-exp /app/everyai-backend-exp
VOLUME /app/data
# Accounts are optional and by magic link (2026-11-08): no dev auth, no server
# model keys (users bring their own), billing parked. The secrets (JWT_SECRET,
# RESEND_API_KEY) come from /opt/everyai/secrets.env on the VM at run time
# (docker-compose env_file), never from the image.
ENV ANOLE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8443 \
    DEV_AUTH=false \
    BILLING_ENABLED=false \
    DATABASE_PATH=data/everyai.db \
    RATE_LIMIT_PER_MINUTE=600
EXPOSE 8443
ENTRYPOINT ["/app/everyai-backend-exp"]
