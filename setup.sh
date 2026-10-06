#!/bin/sh
# Testard OS setup: turns a fresh Alpine, Debian or Ubuntu install into a
# lean, locked-down server for a homelab or a VPS.
#
#   curl -fsSL https://raw.githubusercontent.com/federicolia-coder/testard-os/main/setup.sh -o setup.sh
#   sudo sh setup.sh
#
# Run it with no options to be asked a few questions, or pass options to skip
# them (--yes to also skip the final confirmation; see --help). It is safe to
# run again: it remembers the earlier choices in /etc/testard/setup.conf.
#
# What it changes, step by step, is printed before anything happens. Read
# this file first if you like: it is plain shell, top to bottom.

set -eu
umask 022 # files written below must never be group or world writable

VERSION="0.2.0"
REPO_RAW="https://raw.githubusercontent.com/federicolia-coder/testard-os/main"
AGENT_RAW="https://raw.githubusercontent.com/federicolia-coder/testard-agent/main"
LOG=/var/log/testard-setup.log

# ── Options ───────────────────────────────────────────────────────────────

HOSTNAME_NEW=""
ADMIN=""
SSH_KEYS=""
GITHUB_USER=""
CONTAINERS=""        # docker | podman | none
PROFILE=""           # homelab | server
OPEN_PORTS=""
FIREWALL=1
HARDEN_SSH=1
AUTO_UPDATES=1
AGENT_KEY="${TESTARD_AGENT_KEY:-}"
AGENT_URL="https://platform.testardstudios.it"
ASSUME_YES=0
SAVED=/etc/testard/setup.conf

# Choices from an earlier run are the defaults, so running again (for example
# just to add the agent) doesn't undo them. Read as data, never executed.
saved() { sed -n "s/^$1=//p" "$SAVED" 2>/dev/null | head -n 1; }
if [ -r "$SAVED" ]; then
  ADMIN=$(saved ADMIN); CONTAINERS=$(saved CONTAINERS); OPEN_PORTS=$(saved OPEN_PORTS); PROFILE=$(saved PROFILE)
  FIREWALL=$(saved FIREWALL); HARDEN_SSH=$(saved HARDEN_SSH); AUTO_UPDATES=$(saved AUTO_UPDATES)
  case "$FIREWALL$HARDEN_SSH$AUTO_UPDATES" in [01][01][01]) ;; *) FIREWALL=1; HARDEN_SSH=1; AUTO_UPDATES=1 ;; esac
fi
ARGS_GIVEN=$#

usage() {
  cat <<'EOF'
Usage: sudo sh setup.sh [options]

  --hostname NAME          set the server's name, e.g. homelab-1
  --user NAME              create an admin user (sudo) to log in with
  --ssh-key "ssh-ed25519 …"  authorize this public key for the admin user
  --github USERNAME        authorize the public keys on github.com/USERNAME.keys
  --profile homelab|server homelab: SSH and opened ports reachable only from
                           your local network, and the server answers as
                           NAME.local; server (default): opened ports are
                           reachable from the internet
  --containers ENGINE      docker, podman or none (default: none)
  --open PORTS             ports to allow besides SSH, e.g. 80,443,51820/udp
                           (replaces the list from the last run; "none" for none)
  --agent-key tsk_…        connect this server to Testard (or set TESTARD_AGENT_KEY)
  --agent-url URL          Testard's address (default: https://platform.testardstudios.it)
  --no-firewall            leave the firewall alone
  --no-ssh-hardening       leave the SSH configuration alone
  --no-auto-updates        don't install security updates automatically
  --yes                    don't ask anything; use the options given
  --help, --version
EOF
}

die() { echo "testard-setup: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) HOSTNAME_NEW="${2:-}"; shift 2 ;;
    --user) ADMIN="${2:-}"; shift 2 ;;
    --ssh-key) SSH_KEYS="${SSH_KEYS}${2:-}
"; shift 2 ;;
    --github) GITHUB_USER="${2:-}"; shift 2 ;;
    --containers) CONTAINERS="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --open) OPEN_PORTS="${2:-}"; [ "$OPEN_PORTS" != none ] || OPEN_PORTS=""; shift 2 ;;
    --agent-key) AGENT_KEY="${2:-}"; shift 2 ;;
    --agent-url) AGENT_URL="${2:-}"; shift 2 ;;
    --no-firewall) FIREWALL=0; shift ;;
    --no-ssh-hardening) HARDEN_SSH=0; shift ;;
    --no-auto-updates) AUTO_UPDATES=0; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --version) echo "testard-setup $VERSION"; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root, e.g. with sudo"
[ "$(uname -s)" = "Linux" ] || die "Testard OS setup supports Linux only"

# ── Output ────────────────────────────────────────────────────────────────

if [ -t 1 ]; then B=$(printf '\033[1m'); BLUE=$(printf '\033[1;34m'); DIM=$(printf '\033[2m'); R=$(printf '\033[0m')
else B=""; BLUE=""; DIM=""; R=""; fi

NOTES=""
step() { printf '\n%s==>%s %s%s%s\n' "$BLUE" "$R" "$B" "$*" "$R"; }
say() { printf '    %s\n' "$*"; }
note() { NOTES="${NOTES}  - $*
"; printf '    %snote:%s %s\n' "$B" "$R" "$*"; }
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

# Quiet command: output goes to the log, and to the screen only on failure.
run() {
  log "+ $*"
  out=$("$@" 2>&1) && { [ -z "$out" ] || printf '%s\n' "$out" >> "$LOG"; return 0; }
  status=$?
  printf '%s\n' "$out" >> "$LOG"
  printf '%s\n' "$out" | tail -n 15 >&2
  return "$status"
}

# ── Questions (only when there's a terminal to ask on) ───────────────────

INTERACTIVE=0
if [ "$ASSUME_YES" -eq 0 ] && ( : < /dev/tty ) 2>/dev/null; then INTERACTIVE=1; fi

# ask VAR "Question" "default"
ask() {
  printf '%s%s%s%s: ' "$B" "$2" "$R" "${3:+ [$3]}" > /dev/tty
  IFS= read -r _ans < /dev/tty || _ans=""
  [ -n "$_ans" ] || _ans="$3"
  eval "$1=\$_ans"
}

ask_secret() {
  printf '%s%s%s: ' "$B" "$2" "$R" > /dev/tty
  stty -echo < /dev/tty 2>/dev/null || true
  IFS= read -r _ans < /dev/tty || _ans=""
  stty echo < /dev/tty 2>/dev/null || true
  printf '\n' > /dev/tty
  eval "$1=\$_ans"
}

yes_no() { # yes_no "Question" Y|N
  _yn=""
  while :; do
    ask _yn "$1" "$2"
    case "$_yn" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
  done
}

# ── What are we running on? ──────────────────────────────────────────────

[ -r /etc/os-release ] || die "can't read /etc/os-release"
OS_ID=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
OS_LIKE=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')
OS_NAME=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
case "$OS_ID $OS_LIKE" in
  alpine*) FAMILY=alpine ;;
  debian*|ubuntu*|*debian*) FAMILY=debian ;;
  *) die "$OS_NAME isn't supported yet: use Alpine, Debian or Ubuntu" ;;
esac

if [ -d /run/systemd/system ]; then INIT=systemd
elif command -v openrc-run >/dev/null 2>&1 || [ -x /sbin/openrc-run ]; then INIT=openrc
elif command -v systemctl >/dev/null 2>&1; then INIT=systemd-offline # e.g. a container or chroot
else INIT=none; fi

openrc_running() { [ -e /run/openrc/softlevel ]; }

# enable_service NAME: start now and at every boot.
enable_service() {
  case "$INIT" in
    systemd) run systemctl enable --now "$1" ;;
    systemd-offline) run systemctl enable "$1" || true ;;
    openrc) run rc-update add "$1" default || true
            if openrc_running; then run rc-service "$1" restart || run rc-service "$1" start; fi ;;
    none) note "no init system found: start $1 yourself" ;;
  esac
}

# ── Packages ──────────────────────────────────────────────────────────────

APT_UPDATED=0
pkg_installed() {
  case "$FAMILY" in
    alpine) apk info -e "$@" >/dev/null 2>&1 && [ "$(apk info -e "$@" | wc -l)" -eq $# ] ;;
    debian) for _p in "$@"; do dpkg-query -W -f='${Status}' "$_p" 2>/dev/null | grep -q 'install ok installed' || return 1; done ;;
  esac
}

# Already-installed packages are skipped, so a run works offline when nothing
# new is needed (e.g. the first boot after installing Testard OS).
pkg_install() {
  pkg_installed "$@" && return 0
  case "$FAMILY" in
    alpine) run apk add --no-cache "$@" ;;
    debian)
      if [ "$APT_UPDATED" -eq 0 ]; then run apt-get update; APT_UPDATED=1; fi
      DEBIAN_FRONTEND=noninteractive run apt-get install -y --no-install-recommends "$@" ;;
  esac
}

pkg_available() { # Debian only: does the package exist in the configured repositories?
  apt-cache show "$1" >/dev/null 2>&1
}

# ── Validate input ────────────────────────────────────────────────────────

valid_hostname() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'; }
valid_user() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' && [ "$1" != root ]; }
valid_agent_key() { printf '%s' "$1" | grep -Eq '^tsk_[A-Za-z0-9_-]{43}$'; }
valid_pubkey() { printf '%s' "$1" | grep -Eq '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/=]+( .*)?$'; }

# Ports: "80,443,51820/udp" → lines of "tcp 80", "tcp 443", "udp 51820".
parse_ports() {
  printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r p; do
    p=$(printf '%s' "$p" | tr -d ' ')
    [ -n "$p" ] || continue
    proto=tcp
    case "$p" in */udp) proto=udp; p=${p%/udp} ;; */tcp) p=${p%/tcp} ;; esac
    printf '%s' "$p" | grep -Eq '^[0-9]{1,5}(-[0-9]{1,5})?$' || { echo "bad"; continue; }
    for n in $(printf '%s' "$p" | tr '-' ' '); do
      if [ "$n" -lt 1 ] || [ "$n" -gt 65535 ]; then echo "bad"; continue 2; fi
    done
    echo "$proto $p"
  done
}

# ── Ask what's missing ────────────────────────────────────────────────────

CURRENT_HOST=$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)

if [ "$INTERACTIVE" -eq 1 ] && [ "$ARGS_GIVEN" -eq 0 ]; then
  printf '\n%stestard%s.%s OS setup %s\n' "$B" "$BLUE" "$R" "$VERSION"
  printf '%sOn %s. Press Enter to accept the value in brackets.%s\n\n' "$DIM" "$OS_NAME" "$R"

  [ -n "$HOSTNAME_NEW" ] || ask HOSTNAME_NEW "Server name" "$CURRENT_HOST"

  if [ -z "$ADMIN" ]; then
    existing=$(awk -F: '$3>=1000 && $3<60000 {print $1; exit}' /etc/passwd)
    ask ADMIN "Admin user to log in with (empty for none)" "$existing"
  fi

  if [ -n "$ADMIN" ] && [ -z "$SSH_KEYS" ] && [ -z "$GITHUB_USER" ]; then
    ask GITHUB_USER "GitHub username to take SSH keys from (empty to paste one, or skip)" ""
    if [ -z "$GITHUB_USER" ]; then
      ask _k "Public SSH key, e.g. ssh-ed25519 AAAA… (empty to skip)" ""
      [ -z "$_k" ] || SSH_KEYS="$_k
"
    fi
  fi

  if [ -z "$CONTAINERS" ]; then
    ask CONTAINERS "Container engine: docker, podman or none" "docker"
  else
    ask CONTAINERS "Container engine: docker, podman or none" "$CONTAINERS"
  fi

  if [ "$FIREWALL" -eq 1 ]; then
    ask OPEN_PORTS "Ports to open besides SSH, e.g. 80,443 (none for none)" "${OPEN_PORTS:-none}"
    [ "$OPEN_PORTS" != none ] || OPEN_PORTS=""
  fi

  if [ -z "$AGENT_KEY" ]; then
    printf '%sTo see this server in Testard: Cloud Providers → Connect provider → Any server, then copy the key (tsk_…).%s\n' "$DIM" "$R" > /dev/tty
    ask_secret AGENT_KEY "Testard agent key (empty to skip)"
  fi
fi

[ -n "$HOSTNAME_NEW" ] || HOSTNAME_NEW="$CURRENT_HOST"
[ -n "$CONTAINERS" ] || CONTAINERS=none
[ -n "$PROFILE" ] || PROFILE=server
case "$PROFILE" in homelab|server) ;; *) die "--profile must be homelab or server" ;; esac
HOSTNAME_NEW=$(printf '%s' "$HOSTNAME_NEW" | tr '[:upper:]' '[:lower:]')

valid_hostname "$HOSTNAME_NEW" || die "the server name may use letters, digits and dashes (up to 63), e.g. homelab-1"
[ -z "$ADMIN" ] || valid_user "$ADMIN" || die "the user name must be lower case letters, digits, - or _, and not root"
case "$CONTAINERS" in docker|podman|none) ;; *) die "--containers must be docker, podman or none" ;; esac
[ -z "$AGENT_KEY" ] || valid_agent_key "$AGENT_KEY" || die "that isn't a Testard agent key: it starts with tsk_ and is 47 characters long"
[ -z "$GITHUB_USER" ] || printf '%s' "$GITHUB_USER" | grep -Eq '^[A-Za-z0-9-]{1,39}$' || die "that isn't a GitHub username"
PORTS=$(parse_ports "$OPEN_PORTS")
case "$PORTS" in *bad*) die "--open takes ports like 80,443,8000-8100,51820/udp" ;; esac
if [ -n "$SSH_KEYS" ] && [ -z "$ADMIN" ]; then die "--ssh-key and --github need --user"; fi
if [ -n "$GITHUB_USER" ] && [ -z "$ADMIN" ]; then die "--ssh-key and --github need --user"; fi
printf '%s' "$SSH_KEYS" | while IFS= read -r k; do
  [ -z "$k" ] || valid_pubkey "$k" || die "that doesn't look like a public SSH key: ${k%"${k#??????????????????????????}"}…"
done

# Firewalls we shouldn't fight with.
OTHER_FIREWALL=""
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then OTHER_FIREWALL=ufw; fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then OTHER_FIREWALL=firewalld; fi

# ── The plan ──────────────────────────────────────────────────────────────

echo
echo "${B}This is what will happen on $OS_NAME:${R}"
[ "$HOSTNAME_NEW" = "$CURRENT_HOST" ] || say "Rename the server to $HOSTNAME_NEW"
[ -z "$ADMIN" ] || say "Admin user $ADMIN with sudo${GITHUB_USER:+, SSH keys from github.com/$GITHUB_USER}${SSH_KEYS:+, with the SSH key given}"
[ "$HARDEN_SSH" -eq 0 ] || say "SSH: keys only, no root login with a password (only if a key is in place, so you can't be locked out)"
if [ "$FIREWALL" -eq 1 ]; then
  if [ -n "$OTHER_FIREWALL" ]; then say "Firewall: left to $OTHER_FIREWALL, which is already active"
  else say "Firewall: block incoming connections except SSH$(printf '%s' "$PORTS" | awk 'NF{printf ", %s%s", $2, ($1=="udp" ? "/udp" : "")}')$( [ "$PROFILE" = homelab ] && printf ', and only from your local network')"; fi
fi
[ "$PROFILE" = server ] || say "Answer on the local network as $HOSTNAME_NEW.local"
[ "$AUTO_UPDATES" -eq 0 ] || say "Install security updates automatically every day"
[ "$CONTAINERS" = none ] || say "Install $CONTAINERS with compose"
say "Lighter defaults: capped system logs$( [ "$FAMILY" = debian ] && printf ', no recommended extras from apt')"
say "A login screen with IP, memory, disk and containers at a glance"
[ -z "$AGENT_KEY" ] || say "Install the Testard agent so the server reports to $AGENT_URL"
echo

if [ "$INTERACTIVE" -eq 1 ]; then
  yes_no "Go ahead?" Y || { echo "Nothing changed."; exit 0; }
fi

mkdir -p /etc/testard
: >> "$LOG"; chmod 0600 "$LOG"
cat > "$SAVED" <<EOF
# Choices from the last run of testard-setup, used as defaults next time.
ADMIN=$ADMIN
PROFILE=$PROFILE
CONTAINERS=$CONTAINERS
OPEN_PORTS=$OPEN_PORTS
FIREWALL=$FIREWALL
HARDEN_SSH=$HARDEN_SSH
AUTO_UPDATES=$AUTO_UPDATES
EOF
log "testard-setup $VERSION on $OS_NAME (init: $INIT)"

# ── 1. Base packages ──────────────────────────────────────────────────────

step "Base packages"
case "$FAMILY" in
  alpine) pkg_install ca-certificates curl openssh-server sudo tzdata ;;
  debian) pkg_install ca-certificates curl openssh-server sudo ;;
esac
[ "$FIREWALL" -eq 0 ] || [ -n "$OTHER_FIREWALL" ] || pkg_install nftables
say "done"

# ── 2. Name ───────────────────────────────────────────────────────────────

if [ "$HOSTNAME_NEW" != "$CURRENT_HOST" ]; then
  step "Server name: $HOSTNAME_NEW"
  if [ "$INIT" = systemd ] && command -v hostnamectl >/dev/null 2>&1; then
    run hostnamectl set-hostname "$HOSTNAME_NEW" || note "couldn't rename the server (hostnamectl failed)"
  else
    printf '%s\n' "$HOSTNAME_NEW" > /etc/hostname 2>/dev/null || true
    run hostname "$HOSTNAME_NEW" || note "the new name applies after a reboot"
  fi
  # So sudo and friends can resolve the new name.
  if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
    sed "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$HOSTNAME_NEW/" /etc/hosts > /etc/hosts.testard && cat /etc/hosts.testard > /etc/hosts && rm -f /etc/hosts.testard
  else
    printf '127.0.1.1\t%s\n' "$HOSTNAME_NEW" >> /etc/hosts 2>/dev/null || true
  fi
  say "done"
fi

# ── 3. Admin user ─────────────────────────────────────────────────────────

if [ -n "$ADMIN" ]; then
  step "Admin user: $ADMIN"
  case "$FAMILY" in alpine) SUDO_GROUP=wheel ;; debian) SUDO_GROUP=sudo ;; esac
  if id "$ADMIN" >/dev/null 2>&1; then
    say "already exists"
  else
    case "$FAMILY" in
      alpine) run adduser -D -s /bin/sh "$ADMIN" ;;
      debian) run useradd --create-home --shell /bin/bash "$ADMIN" ;;
    esac
    say "created"
  fi
  case "$FAMILY" in
    alpine) run addgroup "$ADMIN" "$SUDO_GROUP" || true ;;
    debian) run usermod -aG "$SUDO_GROUP" "$ADMIN" ;;
  esac
  mkdir -p /etc/sudoers.d
  if [ "$FAMILY" = alpine ]; then
    printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-testard-wheel
    chmod 0440 /etc/sudoers.d/10-testard-wheel
  fi

  HOME_DIR=$(awk -F: -v u="$ADMIN" '$1==u {print $6}' /etc/passwd)
  ADMIN_GROUP=$(id -gn "$ADMIN")

  if [ -n "$GITHUB_USER" ]; then
    gh_keys=$(curl -fsSL -m 20 "https://github.com/$GITHUB_USER.keys") || die "couldn't fetch github.com/$GITHUB_USER.keys"
    gh_count=0
    for k in $(printf '%s\n' "$gh_keys" | tr ' ' '#'); do
      k=$(printf '%s' "$k" | tr '#' ' ')
      valid_pubkey "$k" && SSH_KEYS="${SSH_KEYS}${k} github:${GITHUB_USER}
" && gh_count=$((gh_count + 1))
    done
    [ "$gh_count" -gt 0 ] || die "github.com/$GITHUB_USER has no public SSH keys: add one at github.com/settings/keys"
    say "$gh_count SSH key(s) from github.com/$GITHUB_USER"
  fi

  if [ -n "$SSH_KEYS" ]; then
    install -d -m 0700 -o "$ADMIN" -g "$ADMIN_GROUP" "$HOME_DIR/.ssh"
    AK="$HOME_DIR/.ssh/authorized_keys"
    touch "$AK"
    printf '%s' "$SSH_KEYS" | while IFS= read -r k; do
      [ -n "$k" ] || continue
      # Compare on type and key only, so a different comment isn't a new key.
      body=$(printf '%s' "$k" | awk '{print $1" "$2}')
      grep -qF "$body" "$AK" || printf '%s\n' "$k" >> "$AK"
    done
    chown "$ADMIN:$ADMIN_GROUP" "$AK"; chmod 0600 "$AK"
    say "SSH keys in $AK"
  fi

  # sudo needs a password; without one, let this admin use sudo without it.
  pw=$(awk -F: -v u="$ADMIN" '$1==u {print $2}' /etc/shadow 2>/dev/null)
  case "$pw" in
    ''|'!'*|'*'*)
      pw_set=0
      if [ "$INTERACTIVE" -eq 1 ] && yes_no "Set a password for $ADMIN, used by sudo?" Y; then
        for _try in 1 2 3; do
          if passwd "$ADMIN" < /dev/tty > /dev/tty 2>&1; then pw_set=1; break; fi
        done
      fi
      if [ "$pw_set" -eq 0 ] && [ ! -f "/etc/sudoers.d/90-testard-$ADMIN" ]; then
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ADMIN" > "/etc/sudoers.d/90-testard-$ADMIN"
        chmod 0440 "/etc/sudoers.d/90-testard-$ADMIN"
        note "$ADMIN has no password, so sudo won't ask for one. Set one with: sudo passwd $ADMIN, then remove /etc/sudoers.d/90-testard-$ADMIN"
      fi ;;
  esac
fi

# ── 4. SSH ────────────────────────────────────────────────────────────────

[ -f /etc/ssh/ssh_host_ed25519_key ] || run ssh-keygen -A
mkdir -p /run/sshd && chmod 0755 /run/sshd # sshd -t needs it, and only the ssh service creates it
SSH_PORTS=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -u | tr '\n' ' ')
[ -n "$SSH_PORTS" ] || SSH_PORTS=22

has_keys() { # has_keys USER: does this user have at least one authorized key?
  h=$(awk -F: -v u="$1" '$1==u {print $6}' /etc/passwd)
  [ -n "$h" ] && [ -s "$h/.ssh/authorized_keys" ] && grep -Eq '^(ssh-|ecdsa-|sk-)' "$h/.ssh/authorized_keys"
}

restart_ssh() {
  case "$INIT" in
    systemd) run systemctl try-reload-or-restart ssh.service 2>/dev/null || run systemctl try-reload-or-restart sshd.service || true ;;
    openrc) if openrc_running; then run rc-service sshd reload || run rc-service sshd restart || true; fi ;;
  esac
}

if [ "$HARDEN_SSH" -eq 1 ]; then
  step "SSH"
  if [ -n "$ADMIN" ] && has_keys "$ADMIN"; then ROOT_LOGIN=no; LOGIN_USER=$ADMIN
  elif has_keys root; then ROOT_LOGIN=prohibit-password; LOGIN_USER=root
  else LOGIN_USER=""; fi

  if [ -z "$LOGIN_USER" ]; then
    note "SSH left as it is: no SSH key is set up yet, and turning off passwords now would lock you out. Run again with --user and --github or --ssh-key."
  else
    # Drop-in files are read in order and the first value wins, so this one
    # (01-) takes precedence over cloud-init's 50-cloud-init.conf.
    mkdir -p /etc/ssh/sshd_config.d
    if ! grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
      { echo 'Include /etc/ssh/sshd_config.d/*.conf'; cat /etc/ssh/sshd_config; } > /etc/ssh/sshd_config.testard
      cat /etc/ssh/sshd_config.testard > /etc/ssh/sshd_config && rm -f /etc/ssh/sshd_config.testard
    fi
    cat > /etc/ssh/sshd_config.d/01-testard.conf <<EOF
# Written by testard-setup. Remove this file to go back to the defaults.
PermitRootLogin $ROOT_LOGIN
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
    if sshd -t 2>>"$LOG"; then
      SSH_APPLIED=1
      restart_ssh
      say "keys only; log in as $LOGIN_USER (root login: $ROOT_LOGIN)"
      say "port(s): $SSH_PORTS"
    else
      rm -f /etc/ssh/sshd_config.d/01-testard.conf
      note "the SSH settings didn't pass sshd -t, so they were not applied (details in $LOG)"
    fi
  fi
  enable_service "$( [ "$FAMILY" = alpine ] && echo sshd || echo ssh)" || true
fi

# ── 5. Firewall ───────────────────────────────────────────────────────────

if [ "$FIREWALL" -eq 1 ]; then
  step "Firewall"
  if [ -n "$OTHER_FIREWALL" ]; then
    note "$OTHER_FIREWALL is already active, so the Testard firewall wasn't added. Open ports there."
  else
    NFT=$(command -v nft || echo /usr/sbin/nft)
    tcp_ports=$( { for p in $SSH_PORTS; do echo "$p"; done; printf '%s\n' "$PORTS" | awk '$1=="tcp"{print $2}'; } | sort -un | paste -sd, - | sed 's/,/, /g')
    udp_ports=$(printf '%s\n' "$PORTS" | awk '$1=="udp"{print $2}' | sort -un | paste -sd, - | sed 's/,/, /g')
    # Homelab: only devices on the local network (and Tailscale's range) can
    # connect; it also answers mDNS so NAME.local works.
    if [ "$PROFILE" = homelab ]; then
      from4="ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 } "
      from6="ip6 saddr { fc00::/7, fe80::/10 } "
      who="local network"
    else
      from4=""; from6=""; who="anyone"
    fi
    allow() { # allow "match" "comment": one line, or one per IP family on a homelab
      if [ -n "$from4" ]; then
        printf '    %s%s accept comment "%s"\n' "$from4" "$1" "$2"
        printf '    %s%s accept comment "%s"\n' "$from6" "$1" "$2"
      else
        printf '    %s accept comment "%s"\n' "$1" "$2"
      fi
    }
    # Its own table, so it never touches rules from Docker or anyone else.
    cat > /etc/testard/firewall.nft.new <<EOF
#!$NFT -f
# Written by testard-setup. Incoming connections are dropped unless allowed
# below. Change ports with: sudo testard-setup --open 80,443
# (edits made here are replaced the next time testard-setup runs).
# Note: ports published by Docker containers are handled by Docker's own
# rules and are reachable even if they aren't listed here.

table inet testard
delete table inet testard

table inet testard {
  chain input {
    type filter hook input priority filter; policy drop;
    iif lo accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto { icmp, ipv6-icmp } accept
    udp dport 546 ip6 daddr fe80::/64 accept comment "DHCPv6"
$(allow "tcp dport { $tcp_ports }" "SSH and opened ports, from $who")
$( [ -z "$udp_ports" ] || allow "udp dport { $udp_ports }" "opened ports, from $who")
$( [ "$PROFILE" = server ] || allow "udp dport 5353" "mDNS: NAME.local")
  }
}
EOF
    if run "$NFT" -c -f /etc/testard/firewall.nft.new; then
      mv /etc/testard/firewall.nft.new /etc/testard/firewall.nft
      case "$INIT" in
        systemd|systemd-offline)
          cat > /etc/systemd/system/testard-firewall.service <<EOF
[Unit]
Description=Testard firewall
Wants=network-pre.target
Before=network-pre.target
After=nftables.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT -f /etc/testard/firewall.nft
ExecReload=$NFT -f /etc/testard/firewall.nft
ExecStop=$NFT delete table inet testard

[Install]
WantedBy=sysinit.target
EOF
          [ "$INIT" = systemd-offline ] || run systemctl daemon-reload
          if [ "$INIT" = systemd ]; then run systemctl enable testard-firewall.service && run systemctl restart testard-firewall.service
          else enable_service testard-firewall.service; fi ;;
        openrc)
          cat > /etc/init.d/testard-firewall <<EOF
#!/sbin/openrc-run
description="Testard firewall"

depend() {
  before net
  after nftables iptables
}

start() {
  ebegin "Loading the Testard firewall"
  $NFT -f /etc/testard/firewall.nft
  eend \$?
}

stop() {
  ebegin "Removing the Testard firewall"
  $NFT delete table inet testard 2>/dev/null
  eend 0
}
EOF
          chmod 0755 /etc/init.d/testard-firewall
          run rc-update add testard-firewall boot || true
          if openrc_running; then run rc-service testard-firewall restart || true; fi ;;
        none) run "$NFT" -f /etc/testard/firewall.nft || true
              note "the firewall is on now but won't come back after a reboot (no init system found)" ;;
      esac
      say "incoming allowed from $who: tcp ${tcp_ports}${udp_ports:+, udp $udp_ports}"
    else
      rm -f /etc/testard/firewall.nft.new
      note "the firewall rules didn't pass nft's check, so they were not applied (details in $LOG)"
    fi
  fi
fi

# ── 6. Automatic security updates ─────────────────────────────────────────

if [ "$AUTO_UPDATES" -eq 1 ]; then
  step "Automatic security updates"
  case "$FAMILY" in
    debian)
      pkg_install unattended-upgrades
      cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Written by testard-setup: refresh package lists and install security
// updates every day. Reboots are never automatic.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
      say "unattended-upgrades installs security updates daily" ;;
    alpine)
      # Alpine's stable branches only receive fixes, so upgrading is safe.
      cat > /etc/periodic/daily/testard-updates <<'EOF'
#!/bin/sh
# Written by testard-setup: install updates from this Alpine release daily.
apk upgrade --no-cache --update-cache >> /var/log/testard-updates.log 2>&1
EOF
      chmod 0755 /etc/periodic/daily/testard-updates
      enable_service crond
      say "apk upgrade runs daily (log: /var/log/testard-updates.log)" ;;
  esac
  say "a kernel update needs a reboot: the login screen will tell you"
fi

# ── 7. Lighter defaults ───────────────────────────────────────────────────

step "Lighter defaults"
if [ "$FAMILY" = debian ]; then
  cat > /etc/apt/apt.conf.d/90testard-lean <<'EOF'
// Written by testard-setup: install only what a package needs, not its
// "recommended" extras. Remove this file to go back.
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
  say "apt installs only required dependencies"
fi
if [ "$INIT" = systemd ] || [ "$INIT" = systemd-offline ]; then
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/10-testard.conf <<'EOF'
# Written by testard-setup: keep system logs small.
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=30M
EOF
  [ "$INIT" = systemd-offline ] || run systemctl restart systemd-journald || true
  say "system logs capped at 100 MB"
else
  # Alpine's syslog keeps one small file by default; rotate it weekly.
  if [ -d /etc/logrotate.d ] || [ "$FAMILY" = alpine ]; then
    cat > /etc/periodic/weekly/testard-logs <<'EOF'
#!/bin/sh
# Written by testard-setup: keep /var/log/messages under 10 MB.
f=/var/log/messages
[ -f "$f" ] && [ "$(wc -c < "$f")" -gt 10485760 ] && mv "$f" "$f.old" && kill -HUP "$(cat /var/run/syslogd.pid 2>/dev/null)" 2>/dev/null
exit 0
EOF
    chmod 0755 /etc/periodic/weekly/testard-logs
    say "system log rotated above 10 MB"
  fi
fi

# ── 7b. Local network name (homelab) ──────────────────────────────────────

if [ "$PROFILE" = homelab ]; then
  step "Local network name: $HOSTNAME_NEW.local"
  case "$FAMILY" in
    alpine) pkg_install avahi dbus; enable_service dbus; enable_service avahi-daemon ;;
    debian) pkg_install avahi-daemon; enable_service avahi-daemon ;;
  esac
  say "other devices on your network can reach it as $HOSTNAME_NEW.local"
fi

# ── 8. Containers ─────────────────────────────────────────────────────────

if [ "$CONTAINERS" != none ]; then
  step "Containers: $CONTAINERS"
  case "$FAMILY:$CONTAINERS" in
    alpine:docker) pkg_install docker docker-cli-compose; enable_service docker ;;
    alpine:podman) pkg_install podman podman-compose ;;
    debian:docker)
      if pkg_available docker-compose-v2; then compose=docker-compose-v2; else compose=docker-compose; fi
      pkg_install docker.io "$compose"; enable_service docker ;;
    debian:podman) pkg_install podman podman-compose ;;
  esac
  if [ "$CONTAINERS" = docker ] && [ -n "$ADMIN" ]; then
    if case "$FAMILY" in alpine) run addgroup "$ADMIN" docker ;; debian) run usermod -aG docker "$ADMIN" ;; esac; then
      say "$ADMIN can use docker without sudo (log in again first)"
    fi
  fi
  say "done: try '$CONTAINERS compose version'"
fi

# ── 9. Login screen ───────────────────────────────────────────────────────

step "Login screen"
cat > /etc/profile.d/testard-motd.sh <<'EOF'
# Written by testard-setup: a short status when you log in.
# Remove this file to turn it off.
if [ -t 1 ] && [ -z "${TESTARD_MOTD_SHOWN:-}" ]; then
  export TESTARD_MOTD_SHOWN=1
  _t_mb() { awk -v k="$1" '$1==k":" {printf "%d", $2/1024}' /proc/meminfo; }
  _t_human() { awk -v m="$1" 'BEGIN { if (m >= 1024) printf "%.1f GB", m/1024; else printf "%d MB", m }'; }
  _t_total=$(_t_mb MemTotal); _t_avail=$(_t_mb MemAvailable)
  _t_up=$(awk '{d=int($1/86400); h=int($1%86400/3600); m=int($1%3600/60); if (d) printf "%d day%s, %d h", d, (d>1?"s":""), h; else if (h) printf "%d h %d min", h, m; else printf "%d min", m}' /proc/uptime)
  _t_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
  _t_disk=$(df -Pk / | awk 'NR==2 {printf "%.1f GB of %.1f GB (%s)", $3/1048576, $2/1048576, $5}')
  _t_load=$(cut -d' ' -f1-3 /proc/loadavg)
  printf '\n  \033[1mtestard\033[1;34m.\033[0m  \033[1m%s\033[0m\n' "$(cat /proc/sys/kernel/hostname)"
  printf '  IP         %s\n' "${_t_ip:-no network}"
  printf '  Up         %s   load %s\n' "$_t_up" "$_t_load"
  printf '  Memory     %s used of %s\n' "$(_t_human $((_t_total - _t_avail)))" "$(_t_human "$_t_total")"
  printf '  Disk       %s used\n' "$_t_disk"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf '  Containers %s running\n' "$(docker ps -q | wc -l | tr -d ' ')"
  elif command -v podman >/dev/null 2>&1; then
    printf '  Containers %s running\n' "$(podman ps -q 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [ -x /usr/local/bin/testard-agent ]; then
    printf '  Testard    reporting every minute\n'
  else
    printf '  Testard    not connected: sudo testard-setup --agent-key tsk_...\n'
  fi
  if [ -f /var/run/reboot-required ]; then
    printf '  \033[1mRestart needed\033[0m to finish an update: sudo reboot\n'
  elif [ -d "/lib/modules" ] && [ ! -d "/lib/modules/$(uname -r)" ]; then
    printf '  \033[1mRestart needed\033[0m to use the updated kernel: sudo reboot\n'
  fi
  echo
  unset -f _t_mb _t_human 2>/dev/null
  unset _t_total _t_avail _t_up _t_ip _t_disk _t_load
fi
EOF
chmod 0644 /etc/profile.d/testard-motd.sh
# The status above replaces the long default welcome text.
if [ "$FAMILY" = alpine ] && grep -q 'Welcome to Alpine' /etc/motd 2>/dev/null; then : > /etc/motd; fi
say "shown at every login"

# Keep a copy of this script so it can be run again later.
mkdir -p /usr/local/sbin
if [ -n "${TESTARD_SETUP_SOURCE:-}" ]; then
  install -m 0755 "$TESTARD_SETUP_SOURCE" /usr/local/sbin/testard-setup
elif [ -f "$0" ] && head -n 3 "$0" | grep -q 'Testard OS setup'; then
  [ "$(readlink -f "$0")" = /usr/local/sbin/testard-setup ] || install -m 0755 "$0" /usr/local/sbin/testard-setup
else
  tmp=$(mktemp)
  if curl -fsSL -m 30 "$REPO_RAW/setup.sh" -o "$tmp" && head -n 3 "$tmp" | grep -q 'Testard OS setup'; then
    install -m 0755 "$tmp" /usr/local/sbin/testard-setup
  fi
  rm -f "$tmp"
fi

# ── 10. Testard agent ─────────────────────────────────────────────────────

if [ -n "$AGENT_KEY" ]; then
  step "Testard agent"
  installer=$(mktemp)
  if [ -n "${TESTARD_AGENT_INSTALLER:-}" ]; then cp "$TESTARD_AGENT_INSTALLER" "$installer"
  else curl -fsSL -m 30 "$AGENT_RAW/install.sh" -o "$installer" || die "couldn't download the Testard agent installer"; fi
  head -n 1 "$installer" | grep -q '^#!/bin/sh' || die "the downloaded agent installer doesn't look right"
  if sh "$installer" --key "$AGENT_KEY" --url "$AGENT_URL" 2>&1 | sed 's/^/    /'; then :; fi
  rm -f "$installer"
  if [ -x /usr/local/bin/testard-agent ]; then say "check it with: testard-agent status"
  else note "the agent didn't install (see above)"; fi
fi

# ── Done ──────────────────────────────────────────────────────────────────

printf '\n%sDone.%s %s is ready.\n' "$B" "$R" "$HOSTNAME_NEW"
if [ -n "$NOTES" ]; then printf '\n%sWorth knowing:%s\n%s' "$B" "$R" "$NOTES"; fi
if [ "${SSH_APPLIED:-0}" -eq 1 ]; then
  printf '\n%sBefore closing this session%s, check that you can log in from another terminal:\n    ssh %s@%s\n' \
    "$B" "$R" "$LOGIN_USER" "$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')"
fi
printf '\nRun it again any time: sudo testard-setup --help   (log: %s)\n' "$LOG"
