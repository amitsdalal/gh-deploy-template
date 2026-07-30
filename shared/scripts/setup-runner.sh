#!/usr/bin/env bash
#
# setup-runner.sh -- manage GitHub Actions self-hosted runners for
#                    OWNER/REPO on AlmaLinux 10.
#
# INSTALL (run once per environment; each label gets its own directory,
# runner name and systemd service, so prod and uat deploy independently):
#
#   sudo ./setup-runner.sh --token <TOKEN_1> --label prod
#   sudo ./setup-runner.sh --token <TOKEN_2> --label uat
#
#   Tokens are SINGLE-USE and expire in ~1h. Get one per runner from:
#   https://github.com/OWNER/REPO/settings/actions/runners
#   -> New self-hosted runner
#
# UNINSTALL (stop the service, deregister from GitHub, optionally delete files):
#
#   # a runner installed by this script
#   sudo ./setup-runner.sh --uninstall --label uat --token <REMOVAL_TOKEN>
#
#   # a runner installed some other way, or belonging to another repo
#   sudo ./setup-runner.sh --uninstall --dir /home/<user>/actions-runner \
#        --token <REMOVAL_TOKEN> --purge
#
#   The REMOVAL token is different from the registration token and comes from
#   the repo that runner belongs to: Settings -> Actions -> Runners -> click the
#   runner -> Remove. If you cannot get one (repo gone, no access), omit --token
#   and the script deregisters locally only -- you must then delete the stale
#   entry by hand in the GitHub UI.
#
# What install does: ensures Docker CE + the compose plugin, ensures an
# unprivileged runner user, downloads the latest runner, registers it, starts it
# as a service. Idempotent -- each step is skipped if already satisfied.
#
# Tokens are never echoed or written to disk by this script.
#
set -euo pipefail

REPO_URL="${REPO_URL:-}"   # e.g. https://github.com/OWNER/REPO -- or pass --url
RUNNER_USER="${RUNNER_USER:-ghrunner}"   # unprivileged account the runner runs as
LABEL=""
NAME=""
DIR=""
TOKEN="${RUNNER_TOKEN:-}"
MODE="install"
PURGE="no"

die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
skip() { printf '    (already done) %s\n' "$*"; }

# ---------------------------------------------------------------- args
while [ $# -gt 0 ]; do
  case "$1" in
    --token)     TOKEN="${2:-}"; shift 2 ;;
    --label)     LABEL="${2:-}"; shift 2 ;;
    --name)      NAME="${2:-}";  shift 2 ;;
    --url)       REPO_URL="${2:-}"; shift 2 ;;
    --user)      RUNNER_USER="${2:-}"; shift 2 ;;
    --dir)       DIR="${2:-}"; shift 2 ;;
    --uninstall) MODE="uninstall"; shift ;;
    --purge)     PURGE="yes"; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run me with sudo"

# ============================================================== UNINSTALL
if [ "$MODE" = "uninstall" ]; then
  if [ -z "$DIR" ]; then
    [ -n "$LABEL" ] || die "uninstall needs --label or --dir"
    DIR="/home/${RUNNER_USER}/actions-runner-${LABEL}"
  fi
  [ -d "$DIR" ] || die "no runner directory at ${DIR}"
  [ -x "${DIR}/svc.sh" ] || die "${DIR} does not look like a runner install"

  OWNER="$(stat -c '%U' "$DIR")"
  info "uninstalling runner in ${DIR} (owner: ${OWNER})"

  # 1. stop + remove the systemd unit while it still exists
  ( cd "$DIR" && ./svc.sh stop 2>/dev/null || true )
  ( cd "$DIR" && ./svc.sh uninstall 2>/dev/null || true )
  info "systemd service stopped and uninstalled"

  # 2. deregister from GitHub. config.sh must not run as root.
  if [ -f "${DIR}/.runner" ]; then
    if [ -n "$TOKEN" ]; then
      if sudo -u "$OWNER" -H bash -c "cd '${DIR}' && ./config.sh remove --token '${TOKEN}'"; then
        info "deregistered from GitHub"
      else
        warn "remote deregistration failed (token wrong/expired?) -- falling back to local"
        sudo -u "$OWNER" -H bash -c "cd '${DIR}' && ./config.sh remove --local" || true
        warn "delete the stale runner entry manually in the GitHub UI"
      fi
    else
      warn "no --token given: removing local config only"
      sudo -u "$OWNER" -H bash -c "cd '${DIR}' && ./config.sh remove --local" || true
      warn "delete the stale runner entry manually in the GitHub UI"
    fi
  else
    warn "no .runner file -- nothing registered locally"
  fi

  # 3. optionally delete the tree
  if [ "$PURGE" = "yes" ]; then
    rm -rf "$DIR"
    info "deleted ${DIR}"
  else
    info "left files in place (re-run with --purge to delete ${DIR})"
  fi

  echo
  info "remaining runner services on this host"
  systemctl list-units --all --type=service 2>/dev/null \
    | grep -i "actions.runner" | awk '{print "    "$1"  "$4}' || echo "    none"
  exit 0
fi

# ================================================================ INSTALL
[ -n "$TOKEN" ] || die "missing --token (or RUNNER_TOKEN env). Single-use, ~1h."
[ -n "$REPO_URL" ] || die "missing --url https://github.com/OWNER/REPO (or set REPO_URL)"
[ -n "$LABEL" ] || die "missing --label (dev | uat | prod)"
case "$LABEL" in
  dev|uat|prod) ;;
  *) die "--label must be dev, uat or prod -- the workflow's runs-on depends on it" ;;
esac
[ -n "$NAME" ] || NAME="${LABEL}-$(hostname -s)"

# One runner directory PER LABEL so several coexist on this host. Note this is
# deliberately NOT the bare .../actions-runner path, which an existing
# unrelated runner may already occupy.
RUNNER_HOME="${DIR:-/home/${RUNNER_USER}/actions-runner-${LABEL}}"

info "host    : $(hostname -f 2>/dev/null || hostname)"
info "repo    : ${REPO_URL}"
info "label   : ${LABEL}"
info "runner  : ${NAME}"
info "dir     : ${RUNNER_HOME}"
echo

# ---------------------------------------------------------------- 1. docker
if command -v docker >/dev/null 2>&1; then
  skip "docker present ($(docker --version | awk '{print $3}' | tr -d ,))"
else
  info "installing Docker CE"
  dnf -y install dnf-plugins-core >/dev/null
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1 || true
  PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  # AlmaLinux 10 is new; Docker may not publish el10 yet. el9 packages work.
  dnf -y install $PKGS || {
    info "el10 packages unavailable -- falling back to el9"
    dnf -y --releasever=9 install $PKGS
  }
fi

systemctl enable --now docker >/dev/null 2>&1 || die "docker failed to start"
docker compose version >/dev/null 2>&1 \
  || die "'docker compose' plugin missing -- the deploy job needs it (not docker-compose)"
info "docker ok: $(docker compose version | head -1)"

# ---------------------------------------------------------------- 2. user
# One user shared by all runners here. Consequence: every runner in the docker
# group can reach every other environment's containers. Same-server prod+uat is
# namespace-isolated, not security-isolated.
if id -u "$RUNNER_USER" >/dev/null 2>&1; then
  skip "user ${RUNNER_USER} exists"
else
  info "creating unprivileged user ${RUNNER_USER}"
  useradd -m -s /bin/bash "$RUNNER_USER"
fi
usermod -aG docker "$RUNNER_USER"

# ---------------------------------------------------------------- 3. runner
if [ -x "${RUNNER_HOME}/config.sh" ]; then
  skip "runner binaries present at ${RUNNER_HOME}"
else
  info "downloading latest runner"
  V="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$V" ] || die "could not resolve the latest runner version (API rate-limited?)"
  info "version ${V}"
  install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_HOME"
  curl -fsSL -o "/tmp/runner-${LABEL}.tar.gz" \
    "https://github.com/actions/runner/releases/download/v${V}/actions-runner-linux-x64-${V}.tar.gz"
  tar xzf "/tmp/runner-${LABEL}.tar.gz" -C "$RUNNER_HOME"
  rm -f "/tmp/runner-${LABEL}.tar.gz"
  chown -R "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_HOME"
  "${RUNNER_HOME}/bin/installdependencies.sh" >/dev/null
fi

# ---------------------------------------------------------------- 4. register
if [ -f "${RUNNER_HOME}/.runner" ]; then
  skip "already registered (rm ${RUNNER_HOME}/.runner to re-register)"
else
  info "registering with GitHub"
  sudo -u "$RUNNER_USER" -H bash -c "cd '${RUNNER_HOME}' && ./config.sh \
      --url '${REPO_URL}' \
      --token '${TOKEN}' \
      --name '${NAME}' \
      --labels '${LABEL}' \
      --work _work --unattended --replace" \
    || die "registration failed -- token expired/reused, or wrong URL/permissions"
fi

# ---------------------------------------------------------------- 5. service
# svc.sh derives the unit name from owner-repo + runner name, so each label (and
# each repo) gets a distinct service.
if systemctl list-units --all --type=service 2>/dev/null | grep -q "actions.runner.*${NAME}"; then
  skip "systemd service already installed"
else
  info "installing systemd service"
  ( cd "$RUNNER_HOME" && ./svc.sh install "$RUNNER_USER" >/dev/null )
fi
( cd "$RUNNER_HOME" && ./svc.sh start >/dev/null 2>&1 || true )
sleep 3

# ---------------------------------------------------------------- summary
echo
info "status"
( cd "$RUNNER_HOME" && ./svc.sh status 2>/dev/null | head -10 ) || true

echo
info "all runner services on this host"
systemctl list-units --all --type=service 2>/dev/null \
  | grep -i "actions.runner" | awk '{print "    "$1"  "$4}' || echo "    none"

OTHER=$( [ "$LABEL" = prod ] && echo uat || echo prod )
cat <<EOF

------------------------------------------------------------------
Runner '${NAME}' is up with label '${LABEL}'.
Verify it shows "Idle": ${REPO_URL}/settings/actions/runners

Add the other environment on this same server (FRESH token):
    sudo $0 --token <NEW_TOKEN> --label ${OTHER}

GITHUB UI -- per environment (Settings > Environments):
    secret    DOTENV    full .env for that env. Build-time: NEXT_PUBLIC_* are
                        baked into the bundle, so prod and uat are separate
                        image builds, not one image promoted.
    variable  PORT      MUST DIFFER on a shared host, e.g. prod=8080 uat=8081.
                        Both stacks publish 127.0.0.1:\${PORT}:80.
    variable  REPLICAS  container count (start at 1 -- see capacity note)
    prod only: add a required reviewer (= GitLab's when: manual)

GITHUB UI -- once per repo:
    Settings > Actions > General > Fork pull request workflows:
      require approval for outside collaborators. A runner in the docker
      group is root-equivalent here -- do not skip.
    After the first build: Org > Packages > <this repo> >
      Package settings -> give this repo Write access, or the deploy job's
      docker pull fails with 'denied'.

HOST NOTES:
  * nginx already owns :80/:443 on this box. Add a vhost per domain proxying
    to 127.0.0.1:\${PORT} (prod 8080, uat 8081) as separate conf.d files so
    existing config stays untouched.
  * Capacity: ~7.7GB RAM total. Each container runs 2 PM2 instances and each
    Next process wants ~250-400MB. Start with REPLICAS=1 per env (4 processes)
    and scale after measuring.
  * Logs: journalctl -u 'actions.runner.*' -f
------------------------------------------------------------------
EOF
