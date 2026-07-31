#!/bin/bash
# Preview-environment setup for Aviator Verify.
#
# Aviator boots a sandbox from the preview image, checks the runbook's branch
# out at /code, cleans the tree with `git reset --hard` + `git clean -fd`, and
# then runs this script. The contract:
#
#   * runs as root, cwd /code, with PREVIEW_URL injected as the sandbox's
#     public https:// URL
#   * must start the app DETACHED and exit; a script that blocks hits the
#     1800s timeout and fails the preview
#   * exit 0 caches the preview URL. Non-zero fails the preview and surfaces
#     the last 2000 characters of this output in chat
#   * it is skipped entirely when Aviator reconnects to a live sandbox whose
#     branch head is unchanged, so every run here is a genuine cold boot or a
#     new commit
#
# See .aviator/preview/README.md for how the image is built and what it bakes.
set -euo pipefail

LOG=/tmp/preview-timing.log
START=$(date +%s)

t() {
  local now
  now=$(date +%s)
  echo "[$((now - START))s] $1" | tee -a "$LOG"
}

# Run a build step, streaming its output to chat and keeping a copy. These
# builds run for minutes; streaming is the only sign of life while they do.
#
# On failure the tail is re-printed after the banner on purpose: Aviator shows
# only the last 2000 characters of a failed setup script, so the diagnostic has
# to be the last thing written.
#
# Every failure path here exits non-zero rather than falling through to the
# build baked into the image. That binary and bundle were compiled from main:
# starting them would hand the verify agent a healthy preview of the WRONG
# code, and it could report PASS on a branch that does not even compile. A
# false green is worse than no preview.
run_step() {
  local label="$1" logfile="$2"
  shift 2
  t "$label"
  if "$@" 2>&1 | tee "$logfile"; then
    return 0
  fi
  t "ERROR: $label failed — refusing to start grafana from the build baked into"
  t "       the image, which would preview main instead of this branch."
  tail -40 "$logfile" | sed 's/^/    /' || true
  exit 1
}

t "Starting grafana preview setup"

# e2b runs this as root against a /code that was cloned during the image build,
# so git refuses to operate on it until it is marked safe. The Makefile shells
# out to `git rev-parse` for the build ldflags, so this has to come first.
git config --global --add safe.directory /code
cd /code

# e2b forces its own PATH and does not carry the image's ENV into the sandbox.
# The image symlinks go into /usr/local/bin (which is on that PATH); this keeps
# working if the symlink is ever dropped.
export PATH=/usr/local/go/bin:$PATH

# nx's background daemon is pointless for a one-shot build and would outlive
# this script.
export NX_DAEMON=false
# The sandbox has 4 GB total. Node sizes its heap from the machine and will
# happily exceed what is left once webpack's workers are running; the OOM
# killer's "Killed" is far harder to diagnose than a heap-limit stack trace.
export NODE_OPTIONS=--max-old-space-size=2560

BIN=/code/bin/grafana
PORT=3000
APP_LOG=/var/log/app/grafana.log

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# /preview-image-sha records the commit the image's caches were built from. It
# lives outside /code because `git clean -fd` would delete it in there. This
# line is the first-run diagnostic for the whole caching design: if it is
# missing, the git-fetch fast path did not match, Aviator re-cloned, and every
# build below is cold (the preview still works, it is just slow).
BAKED_SHA=""
if [ -f /preview-image-sha ]; then
  BAKED_SHA=$(cat /preview-image-sha)
  t "  build cache baked at $(echo "$BAKED_SHA" | cut -c1-12), branch head is $(git rev-parse --short HEAD)"
else
  t "  WARN: no /preview-image-sha — no baked build cache, expect a slow cold build"
fi

# yarn is the only toolchain here without cheap incrementality, and
# `yarn install --immutable` needs the network, so it is the one step gated on
# a path diff. Everything after it (webpack's filesystem cache, nx's build
# cache, the Go build cache) is genuinely incremental, so those always run and
# decide for themselves what to redo — the same reasoning as letting cargo
# decide in the microbin preview.
#
# --name-only needs tree objects but no blob contents, so it stays cheap on the
# image's blobless clone.
needs_yarn_install=1
if [ -n "$BAKED_SHA" ] && git cat-file -e "${BAKED_SHA}^{commit}" 2>/dev/null; then
  if git diff --name-only "$BAKED_SHA" HEAD -- \
      yarn.lock package.json .yarnrc.yml '*/package.json' | grep -q .; then
    t "  dependency manifests changed since the image was baked"
  else
    needs_yarn_install=0
    t "  dependency manifests unchanged — skipping yarn install"
  fi
fi

if [ "$needs_yarn_install" -eq 1 ]; then
  run_step "Installing frontend dependencies..." /tmp/yarn-install.log \
    yarn install --immutable
fi

# Generated SCSS variable files. `dev`'s nx target declares this as a
# dependency; we run it explicitly because the bundle below bypasses nx. Cheap
# (~4s), so it is not worth gating.
run_step "Generating theme variables..." /tmp/themes-generate.log \
  yarn themes-generate

# Decoupled core datasource plugins. nx-cached against .nx/ (gitignored, so it
# survives the launch cleanup): a cache hit when the branch touched no plugin.
#
# --maxParallel=1 for the same reason as the image build: three concurrent
# webpack processes do not fit in 4 GB, and the one that loses is killed with
# no output at all.
run_step "Building core datasource plugins..." /tmp/plugin-build.log \
  yarn plugin:build --maxParallel=1

# Main frontend bundle. webpack is invoked DIRECTLY, not via `yarn dev`: nx exec
# re-parses trailing args and eats the first --env, so the flags below would
# silently not apply and the 8 GB-hungry type checker would run. This must stay
# byte-identical to the image build's invocation — webpack's persistent cache is
# keyed on the config, so a different flag set misses the baked cache entirely.
# --no-devtool overrides webpack.dev.ts's devtool: 'source-map', which is what
# makes this fit in 4 GB at all: source maps for a graph this size are held in
# memory until emit, and with them on there was no heap cap that worked (3072
# was SIGKILLed by the kernel, 2048 hit V8's own limit). A preview agent never
# opens a debugger.
run_step "Building frontend (webpack, development)..." /tmp/webpack-dev.log \
  env NODE_ENV=dev node_modules/.bin/webpack \
    --config scripts/webpack/webpack.dev.ts \
    --no-devtool \
    --env react19=1 --env noTsCheck=1 --env noLint=1

# Backend. The Go build cache lives outside /code and is never cleaned, so a
# no-op rebuild is cheap and a real one only recompiles what changed.
#
# -v names each package as it compiles: a silent multi-minute step looks
# indistinguishable from a hang in the chat stream, and it is what kept the
# image build's connection alive through the cold compile. On an incremental
# rebuild only the changed packages print, so this stays quiet in practice.
# -p=2 caps parallel compile jobs to fit the 4 GB sandbox.
run_step "Building backend (make build-go)..." /tmp/go-build.log \
  env GOFLAGS="-v -p=2" make build-go

if [ ! -x "$BIN" ]; then
  t "ERROR: $BIN missing after a successful build — nothing to start."
  exit 1
fi

# ---------------------------------------------------------------------------
# Seed data
# ---------------------------------------------------------------------------
#
# A fresh sandbox has an empty SQLite database: no datasource, no dashboard,
# and a "get started" home screen. That gives the verify agent nothing to act
# on for any change to panels, dashboards, navigation or the time picker.
#
# Seeded by provisioning rather than API calls or a baked grafana.db because it
# is declarative, re-applied on every boot, and needs no COPY in the image (the
# "Add custom template" Dockerfile parser rejects COPY).
#
# conf/provisioning is grafana's default provisioning path and is listed in
# permitted_provisioning_paths. `/conf/provisioning/**/*.yaml` is gitignored so
# the YAML survives `git clean -fd`; the dashboard JSON is not gitignored, so it
# is rewritten here on every run. Both are written unconditionally to keep the
# two states from drifting.
t "Writing preview seed provisioning..."
mkdir -p /code/conf/provisioning/datasources \
         /code/conf/provisioning/dashboards \
         /code/conf/provisioning/preview-dashboards

# TestData is a core, in-process backend datasource (registered in
# pkg/services/pluginsintegration/coreplugin), so it needs no external service
# and no network — it generates its data locally.
cat > /code/conf/provisioning/datasources/aviator-preview.yaml <<'YAML'
# Written by .aviator/scripts/preview-setup.sh — not checked in.
apiVersion: 1
datasources:
  - name: TestData
    uid: aviator-preview-testdata
    type: grafana-testdata-datasource
    access: proxy
    isDefault: true
    editable: true
YAML

cat > /code/conf/provisioning/dashboards/aviator-preview.yaml <<'YAML'
# Written by .aviator/scripts/preview-setup.sh — not checked in.
apiVersion: 1
providers:
  - name: Aviator preview
    type: file
    folder: Preview
    allowUiUpdates: true
    options:
      path: /code/conf/provisioning/preview-dashboards
      foldersFromFilesStructure: false
YAML

cat > /code/conf/provisioning/preview-dashboards/overview.json <<'JSON'
{
  "uid": "aviator-preview",
  "title": "Preview Overview",
  "tags": ["aviator", "preview"],
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "refresh": "",
  "time": { "from": "now-6h", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "Random walk",
      "gridPos": { "h": 9, "w": 16, "x": 0, "y": 0 },
      "datasource": { "type": "grafana-testdata-datasource", "uid": "aviator-preview-testdata" },
      "targets": [{ "refId": "A", "scenarioId": "random_walk" }]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "Latest value",
      "gridPos": { "h": 9, "w": 8, "x": 16, "y": 0 },
      "datasource": { "type": "grafana-testdata-datasource", "uid": "aviator-preview-testdata" },
      "targets": [{ "refId": "A", "scenarioId": "random_walk" }]
    },
    {
      "id": 3,
      "type": "table",
      "title": "Sample rows",
      "gridPos": { "h": 9, "w": 12, "x": 0, "y": 9 },
      "datasource": { "type": "grafana-testdata-datasource", "uid": "aviator-preview-testdata" },
      "targets": [{ "refId": "A", "scenarioId": "random_walk_table" }]
    },
    {
      "id": 4,
      "type": "text",
      "title": "About this preview",
      "gridPos": { "h": 9, "w": 12, "x": 12, "y": 9 },
      "options": {
        "mode": "markdown",
        "content": "This dashboard is seeded by `.aviator/scripts/preview-setup.sh` so the preview has something to look at. Data comes from the built-in **TestData** datasource — no external service is reachable from this sandbox."
      }
    }
  ]
}
JSON

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# Aviator's browser reaches this box over the public internet, so bind all
# interfaces. (grafana's default http_addr is already empty/all-interfaces;
# this is explicit so it cannot regress silently.)
export GF_SERVER_HTTP_ADDR=0.0.0.0
export GF_SERVER_HTTP_PORT="$PORT"
# Every absolute URL grafana generates — share links, redirects after login,
# alert links — comes from root_url. PREVIEW_URL is the sandbox's public https
# URL; grafana appends the trailing slash itself.
export GF_SERVER_ROOT_URL="${PREVIEW_URL:-http://127.0.0.1:3000}"
# The Host header is <port>-<sandboxid>.e2b.app, which will never match
# [server] domain. Off by default; explicit because enabling it would break
# every request.
export GF_SERVER_ENFORCE_DOMAIN=false

# app_mode=development makes the backend re-read the assets manifest on every
# request instead of caching it once (pkg/api/webassets), which matches the
# development bundle this box builds, and is how grafana devs run locally.
export GF_DEFAULT_APP_MODE=development

# The frontend built above is the react19 bundle, and it only emits
# assets-manifest-react19.json. The backend picks the manifest from this
# toggle, whose registry default is true — pinning it means a default flip
# upstream cannot leave the server reading a manifest that was never built.
export GF_FEATURE_TOGGLES_ENABLE=react19

# --- Credentials -------------------------------------------------------------
#
# Admin credentials come from Aviator account secrets, declared in the preview
# config's `secrets:` list and injected into this script's environment under the
# secret key's exact name. Nothing in this repo holds a credential, and the
# verify skill refers to the same two keys as {{ secrets.* }}, so the agent and
# the server cannot disagree about the password.
#
# The lowercase spelling is accepted as a fallback: the config's `secrets:` list
# matches keys case-sensitively, but the {{ secrets.* }} placeholders in the
# skill are resolved case-insensitively — so a secret created in the other case
# still reaches the skill while this script would otherwise see nothing.
ADMIN_USER="${GRAFANA_ADMIN_USERNAME:-${grafana_admin_username:-}}"
ADMIN_PASS="${GRAFANA_ADMIN_PASSWORD:-${grafana_admin_password:-}}"

if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
  # Fail rather than fall back to grafana's default admin/admin. The verify
  # agent signs in with the secret values; if they are not here it would type
  # credentials that do not exist and report a working app as a broken login.
  #
  # This has to be checked here because AccountSecret.get_decrypted_values
  # resolves keys with an IN query and omits any that do not exist, so a missing
  # or misspelled key arrives as an unset variable rather than an error.
  t "ERROR: admin credentials were not injected."
  t "       Add account secrets 'GRAFANA_ADMIN_USERNAME' and 'GRAFANA_ADMIN_PASSWORD'"
  t "       (Verify -> Settings -> Secrets), then list both under 'secrets:' in"
  t "       the preview config, spelled the same way. Neither is optional."
  exit 1
fi

# Do not set the password to the literal "admin". LoginCtrl.tsx checks
# `formModel.password !== 'admin'` and, on an exact match, swaps the login form
# for a change-password step — skippable, but an extra interaction in every
# scenario. Any other value goes straight through, and no complexity rules
# apply: [auth.basic] password_policy defaults to false in conf/defaults.ini.
export GF_SECURITY_ADMIN_USER="$ADMIN_USER"
export GF_SECURITY_ADMIN_PASSWORD="$ADMIN_PASS"

# Everything that phones home. The sandbox has no useful egress, and the news
# feed panel on the home dashboard blocks on grafana.com's RSS.
export GF_ANALYTICS_REPORTING_ENABLED=false
export GF_ANALYTICS_CHECK_FOR_UPDATES=false
export GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false
export GF_NEWS_NEWS_FEED_ENABLED=false

# data/ is gitignored, so the SQLite database survives `git clean -fd` and a
# reconnect keeps whatever the agent created in a previous run.
export GF_PATHS_DATA=/code/data
export GF_PATHS_LOGS=/code/data/log
export GF_PATHS_PLUGINS=/code/data/plugins
export GF_PATHS_PROVISIONING=/code/conf/provisioning

mkdir -p /var/log/app "$GF_PATHS_DATA" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS"

# Defensive: Aviator either reconnects (and never runs this script) or cold
# boots a fresh sandbox, so nothing should be listening. Kept because it makes
# a manual re-run safe — an old instance has to die BEFORE the build, since the
# linker writes straight to $BIN and Linux returns ETXTBSY when writing to a
# running executable.
if pgrep -f "$BIN" >/dev/null 2>&1; then
  t "Stopping previous grafana instance..."
  pkill -f "$BIN" || true
  for _ in $(seq 1 10); do
    pgrep -f "$BIN" >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f "$BIN" 2>/dev/null || true
fi

t "Starting grafana on 0.0.0.0:${PORT}..."
setsid "$BIN" server --homepath /code < /dev/null > "$APP_LOG" 2>&1 &
disown

# Do not report ready before the port answers. /api/health is the right probe:
# it returns 503 until the database is migrated and reachable, and the first
# boot in a fresh sandbox runs the full migration set.
t "Waiting for grafana on port ${PORT}..."
for i in $(seq 1 120); do
  if curl -sf -o /tmp/grafana-health.json "http://127.0.0.1:${PORT}/api/health"; then
    t "grafana is up (public URL: ${GF_SERVER_ROOT_URL})"
    break
  fi
  # Fail fast on crash-on-boot, but not before the process can exist:
  # `setsid "$BIN" &` forks a subshell that execs setsid that execs grafana,
  # and until that chain completes pgrep matches nothing. Checking on the first
  # iteration reports a healthy app as dead on a cold box.
  if [ "$i" -ge 4 ] && ! pgrep -f "$BIN" >/dev/null 2>&1; then
    t "ERROR: grafana exited during startup — last log lines:"
    tail -40 "$APP_LOG" | sed 's/^/    /' || true
    exit 1
  fi
  if [ "$i" -eq 120 ]; then
    t "ERROR: grafana did not answer on port ${PORT} — last log lines:"
    tail -40 "$APP_LOG" | sed 's/^/    /' || true
    exit 1
  fi
  sleep 1
done

# Prove the injected credentials actually log in, before declaring the preview
# ready. Nothing here creates that user: grafana does it itself on first start,
# from GF_SECURITY_ADMIN_USER/PASSWORD (ensureMainOrgAndAdminUser in
# pkg/services/sqlstore/sqlstore.go). That function returns early the moment the
# user table is non-empty, so it seeds ONCE — a database surviving into a later
# run keeps the old password and silently ignores the new secret.
#
# data/ is gitignored, so grafana.db outlives `git clean -fd`. In the normal
# flow that is harmless (a cold boot gets a fresh sandbox, and the image never
# ran grafana so it bakes no database), but the failure it would cause is the
# worst kind: a preview that boots perfectly and rejects the only password the
# verify agent has. One request rules it out.
if ! curl -sf -o /dev/null -u "${GF_SECURITY_ADMIN_USER}:${GF_SECURITY_ADMIN_PASSWORD}" \
    "http://127.0.0.1:${PORT}/api/user"; then
  t "ERROR: grafana is serving, but the injected admin credentials were rejected."
  t "       grafana seeds the admin user only when its user table is empty, so an"
  t "       existing ${GF_PATHS_DATA}/grafana.db still holds the OLD password."
  t "       Delete it to reseed, or run: bin/grafana cli admin reset-admin-password"
  exit 1
fi
t "Admin credentials verified"

# Point the org home dashboard at the seeded one, so the agent lands on
# something with panels instead of the empty getting-started screen.
#
# Best-effort: provisioning runs asynchronously after startup, and a preview
# with no seed dashboard is still a usable preview — so a failure here warns
# rather than failing the launch.
for i in $(seq 1 15); do
  if curl -sf -o /dev/null -u "${GF_SECURITY_ADMIN_USER}:${GF_SECURITY_ADMIN_PASSWORD}" \
      "http://127.0.0.1:${PORT}/api/dashboards/uid/aviator-preview"; then
    if curl -sf -o /dev/null -u "${GF_SECURITY_ADMIN_USER}:${GF_SECURITY_ADMIN_PASSWORD}" \
        -X PATCH -H "Content-Type: application/json" \
        -d '{"homeDashboardUID":"aviator-preview"}' \
        "http://127.0.0.1:${PORT}/api/org/preferences"; then
      t "Seed dashboard provisioned and set as the org home dashboard"
    else
      t "  WARN: seed dashboard exists but setting it as home dashboard failed"
    fi
    break
  fi
  if [ "$i" -eq 15 ]; then
    t "  WARN: seed dashboard did not appear — check provisioning errors:"
    grep -i "provisioning" "$APP_LOG" | tail -10 | sed 's/^/    /' || true
  fi
  sleep 1
done

t "Preview environment ready."
