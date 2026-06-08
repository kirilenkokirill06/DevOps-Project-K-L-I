FROM haproxy:2.8-alpine

# HAProxy alpine image already includes a 'haproxy' user/group.
# We explicitly set the container to run as the 'haproxy' user (UID 99).
USER haproxy

# Expose ports >= 1024 to comply with non-root privileges.
# 8080 - HTTP traffic frontend
# 8404 - Stats and Prometheus metrics
EXPOSE 8080 8404
