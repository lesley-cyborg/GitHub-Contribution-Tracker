#!/bin/sh
# Runs ON the EC2 instance via SSM Run Command.
# The caller exports IMAGE, REGISTRY and AWS_DEFAULT_REGION before this script.
set -eu
export HOME=/root

PREV=$(docker inspect -f '{{.Image}}' tracker-app 2>/dev/null || true)

aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker pull "$IMAGE:latest"

run_container() {
  docker rm -f tracker-app >/dev/null 2>&1 || true
  docker run -d --name tracker-app --restart always -p 80:3000 --env-file /etc/tracker.env "$1"
}

healthy() {
  i=0
  while [ "$i" -lt 12 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ || true)
    if [ "$code" != "000" ] && [ "$code" -lt 500 ]; then return 0; fi
    i=$((i + 1))
    sleep 5
  done
  return 1
}

run_container "$IMAGE:latest"

if healthy; then
  docker image prune -f >/dev/null
  echo "deploy ok"
else
  echo "new container unhealthy, rolling back" >&2
  if [ -n "$PREV" ]; then run_container "$PREV"; fi
  exit 1
fi
