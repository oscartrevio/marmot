#!/usr/bin/env bash
# Prepare a throwaway Debian/Ubuntu container for tests/e2e/agent-vm.sh. Runs as root.
#
#   setup.sh [--user NAME] [--minimal]
#
# Installs what the scenario needs: git, Node.js + npm (nodejs.org build), pnpm, fzf (marmot's
# picker) and python3 (the pseudo-terminal driver). By default the container also gets what a
# typical cloud VM has (procps, psmisc, iproute2, sudo) and NAME, if given, passwordless sudo.
# --minimal installs none of those and fails if any of them is present, so marmot is proven to
# work without them.
set -euo pipefail

NODE_VERSION=20.18.0
PNPM_VERSION=9.12.3

user="" minimal=0
while (( $# )); do
  case "$1" in
    --user) user=$2; shift ;;
    --minimal) minimal=1 ;;
    *) echo "setup.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
(( EUID == 0 )) || { echo "setup.sh: run as root" >&2; exit 2; }

pkgs=(ca-certificates curl fzf git python3 xz-utils)
(( minimal )) || pkgs+=(procps psmisc iproute2 sudo)
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >/dev/null

if (( minimal )); then
  present=()
  for c in ps pgrep pkill fuser killall ip ss sudo; do command -v "$c" >/dev/null && present+=("$c"); done
  (( ${#present[@]} == 0 )) || { echo "setup.sh: --minimal, but installed: ${present[*]}" >&2; exit 1; }
fi

case "$(dpkg --print-architecture)" in
  amd64) arch=x64 ;;
  arm64) arch=arm64 ;;
  *) echo "setup.sh: no Node.js build for $(dpkg --print-architecture)" >&2; exit 1 ;;
esac
curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$arch.tar.xz" |
  tar -xJ -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE
npm install -g --no-audit --no-fund --no-update-notifier --loglevel=error "pnpm@$PNPM_VERSION"
rm -rf /root/.npm # SAFE: npm's cache from the global pnpm install above, in a throwaway container

if [[ -n "$user" ]]; then
  id "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"
  if (( ! minimal )); then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"/etc/sudoers.d/90-$user"
    chmod 0440 "/etc/sudoers.d/90-$user"
  fi
fi
echo "setup.sh: ready (node $(node --version), pnpm $(pnpm --version), fzf $(fzf --version | cut -d' ' -f1), minimal=$minimal${user:+, user=$user})"
