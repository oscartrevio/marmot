#!/usr/bin/env bash
# Run the end-to-end agent-VM scenario (tests/e2e/agent-vm.sh) in a throwaway docker container:
#
#   tests/e2e/run.sh [IMAGE] [--root] [--minimal]
#
# IMAGE defaults to debian:12. The scenario runs as a normal user with passwordless sudo, or as
# root with --root; --minimal leaves out procps, psmisc, iproute2 and sudo. Home folders live on
# their own tmpfs, so df measures nothing but the scenario. Needs docker and network access (npm
# registry, nodejs.org, the image's apt mirror). Nothing outside the container is touched.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/../.."

# A plain string, not an array: macOS still ships bash 3.2, where an empty array trips set -u.
image=debian:12 as=user minimal=""
while (( $# )); do
  case "$1" in
    --root) as=root ;;
    --minimal) minimal=--minimal ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    -*) echo "run.sh: unknown option $1" >&2; exit 2 ;;
    *) image=$1 ;;
  esac
  shift
done
command -v docker >/dev/null || { echo "run.sh: docker is not installed" >&2; exit 1; }

# The checkout is mounted read-only; the scenario runs from a copy the user under test can read.
docker run --rm -v "$PWD:/src:ro" \
  --tmpfs /home:rw,exec,size=2g,mode=755 --tmpfs /root:rw,exec,size=2g,mode=700 \
  "$image" bash -c '
  set -e
  /src/tests/e2e/setup.sh '"$minimal"' --user e2e
  cp -r /src /opt/marmot && chown -R e2e /opt/marmot
  if [ '"$as"' = root ]; then exec env MM_E2E=1 HOME=/root /opt/marmot/tests/e2e/agent-vm.sh; fi
  exec runuser -u e2e -- env MM_E2E=1 HOME=/home/e2e USER=e2e /opt/marmot/tests/e2e/agent-vm.sh'
