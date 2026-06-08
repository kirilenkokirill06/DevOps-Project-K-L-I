FROM nginx:1.25-alpine

# The official Nginx alpine image includes an 'nginx' user (UID 101).
# We explicitly set the container to run as the 'nginx' user.
USER nginx

# Expose ports >= 1024 to comply with non-root privileges.
# 8080 - Web server traffic (using proxy_protocol)
# 8081 - Local healthcheck traffic (without proxy_protocol)
EXPOSE 8080 8081
