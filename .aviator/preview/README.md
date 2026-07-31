# Preview environment

Aviator Verify can run this branch as a live app on a public URL, so the verify
agent can drive it in a real browser instead of only reading the diff.

Three pieces, in three different places:

| Piece | Where it lives |
| --- | --- |
| The image (a pre-warmed box with the build baked in) | Built by e2b. `Dockerfile` here is the reviewable copy, **not** the source of truth. |
| The setup script (builds and starts the app) | `.aviator/scripts/preview-setup.sh` in this repo |
| The config (which image, which port, which script) | Aviator's database, edited in the UI |

## Config

Paste this at **Verify → Settings → Verify**, with this repo selected:

```yaml
verify:
  preview:
    - name: default
      image: grafana-prev-1 # display name of the custom template
      port: 3000
      setup: .aviator/scripts/preview-setup.sh
      secrets:
        - GRAFANA_ADMIN_USERNAME
        - GRAFANA_ADMIN_PASSWORD
```

`secrets:` names account secrets (Settings → Secrets); their values are injected
into the setup script as environment variables of the same name, and the verify
skill refers to them as `{{ secrets.GRAFANA_ADMIN_USERNAME }}` /
`{{ secrets.GRAFANA_ADMIN_PASSWORD }}`. They are grafana's admin login. Nothing
in this repo holds the values.

Two things about how keys resolve, both of which the script defends against:

- A key that does not exist is **not** an error — the resolver looks keys up
  with an `IN` query and omits what it cannot find — so the script checks for
  both itself and fails with the missing names rather than booting a grafana
  nobody can log into.
- The `secrets:` list matches keys **case-sensitively** while the
  `{{ secrets.* }}` placeholders resolve **case-insensitively**, so a secret
  created in the other case would reach the skill but not the script. The script
  accepts the lowercase spelling as a fallback.

`image:` is the *display name* you gave the custom template, not the e2b alias.
Saving validates it with the same resolver the launch uses, so a green save
proves the image wiring works. The verify skill is picked up automatically from
`.aviator/verify/skills/default.md` (matching `name: default`).

## Building the image

**Verify → Settings → Sandbox → Custom templates → Add → From Dockerfile**, then
paste the contents of `Dockerfile` in this directory.

Aviator appends two steps of its own before building at 4 CPU / 4 GB:

```
npm install -g @anthropic-ai/claude-code   # needs npm in the image
apt install git git-lfs
```

Expect roughly **15–25 minutes** and a large image — this bakes `node_modules`,
the webpack bundle, the plugin bundles, the grafana binary and the Go build
cache. Measured on e2b: `yarn install` is ~100s, and the earlier layers (apt,
Go, corepack, clone) come back CACHED on a rebuild, so iterating on a later step
resumes there rather than starting over.

> **Check for an alias collision before you build.** Template aliases are derived
> from the database row id (`account-<account>-id-<row>`). A new row that lands
> on an id already used by an older row rebuilds *that* template in place,
> silently replacing another repo's image. If two rows share an alias, delete and
> re-add so the new row gets a fresh id.

Rebuild the template when the base image, the Go or Node version, or the set of
baked build steps changes. Routine dependency bumps do not need one — the setup
script reinstalls when `yarn.lock` moves, it is just slower that run.

## Why it is fast

The launch cleans the checkout with `git clean -fd` — **no `-x`** — so gitignored
files survive. That is the whole caching mechanism, and `.gitignore` is the list
of what may be cached:

| Cache | Why it survives |
| --- | --- |
| `node_modules/`, incl. webpack's persistent cache | `node_modules` is gitignored |
| `public/build/` | `/public/build` is gitignored |
| `public/app/plugins/**/dist/` | gitignored as "core plugin builds" |
| `.nx/` (nx build cache) | `.nx` is gitignored |
| `bin/grafana` | `/bin/*` is gitignored |
| Go build + module caches | live outside `/code`, so git never sees them |

The setup script re-runs webpack, nx and `make build-go` every launch and lets
each decide what to redo. Only `yarn install` is gated on a path diff against
`/preview-image-sha`, the commit the image's caches were built from.

## Testing the script without a full round-trip

The trick is making a local container behave like an e2b sandbox — mainly its
forced PATH, and mounting the script from disk so you can edit and re-run
without rebuilding:

```bash
docker run --rm --platform linux/amd64 \
  -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e PREVIEW_URL=https://3000-fake.e2b.app \
  -v "$PWD/.aviator/scripts:/mnt/scripts:ro" \
  -p 3000:3000 \
  grafana-preview:test \
  bash -c '
    bash /mnt/scripts/preview-setup.sh; echo "SCRIPT_EXIT=$?"
    curl -s -o /dev/null -w "app=%{http_code}\n" http://127.0.0.1:3000/api/health
  '
```

This confirms diagnoses and fixes. It will not find timing bugs — a laptop is
fast enough to hide the startup races that a cold sandbox exposes.

## First-run diagnostic

This line in the launch output tells you whether the caching design is working
at all:

```
[0s]   build cache baked at 2228fe25c9ab, branch head is a1b2c3d
```

Present means the image booted and its caches survived. Missing means the
git-fetch fast path did not match, Aviator re-cloned, and every build ran cold —
the preview still works, it is just slow.

## Known constraints

- **4 GB of RAM** for both the template build and the running sandbox. The
  frontend build runs with `--max-old-space-size=3072` and with
  ForkTsChecker/eslint disabled (the type checker alone asks for an 8 GB heap).
  If a future dependency pushes the build past that, the failure is a bare
  `Killed` from the OOM killer.
- **Do not build the bundle through `yarn dev`.** It is `nx exec -- webpack`,
  and nx re-parses trailing args: `yarn dev --env noTsCheck=1 --env noLint=1`
  arrives as `nx run grafana:"dev" noTsCheck=1 --env noLint=1`, first flag
  eaten, type checker silently back on. Both the image and the setup script
  call `node_modules/.bin/webpack` directly, and they must stay identical —
  webpack's persistent cache is keyed on the config.
- **Plugin builds run one at a time** (`--maxParallel=1`). At nx's default of 3,
  three concurrent webpack processes on the 4 GB builder got one of them killed
  with no output and no heap-limit trace, which is a confusing way to fail.
- **1800s** for the setup script. A cold, cache-missing boot builds all of
  grafana and can approach it.
- The frontend is a **development** build. Correct, but unminified and slow to
  first paint — see the verify skill.
