#!/bin/sh
#
set -e

. ../.env.prod.nginx

CMD=""
COMPOSE_CMD=""

# Use podman if available, docker otherwise
if which -s podman; then
    CMD="podman"
    COMPOSE_CMD="podman-compose"
    COMPOSE_ARG=""
elif which -s docker; then
    CMD="docker"
    COMPOSE_CMD="$CMD"
    COMPOSE_ARG="compose"
else
    echo "ERROR: neither podman nor docker found!"
    exit 1
fi

if ! which -s $CMD; then echo "ERROR command $CMD not found!"; exit 1; fi
if ! which -s $COMPOSE_CMD; then echo "ERROR compose command $COMPOSE_CMD not found!"; exit 1; fi

CWD=$(pwd)

cd $OTTERWIKI_CONTEXT

# This requires that port redirection is done on the host from port 80 to port 8080
$CMD run -it --rm --name certbot -p 8080:80 -v "${OTTERWIKI_VOLUME}:/etc/letsencrypt:rw,Z" certbot/certbot:latest certonly --standalone --non-interactive --agree-tos --email $OTTERWIKI_CERTBOT_EMAIL -d $OTTERWIKI_DOMAIN -v

$COMPOSE_CMD $COMPOSE_ARG -f docker-compose.prod.yml restart nginx 2>/dev/null || echo "nginx container not running, not restarting it"

cd $CWD
