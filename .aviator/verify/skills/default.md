---
description: How to drive the grafana preview environment — logging in, where things live, what the seeded data is, and which parts of grafana this preview cannot exercise.
---

# Verifying grafana in the preview environment

The preview runs a **real grafana server** built from this branch: the Go backend
compiled with `make build-go`, the frontend as a webpack **development** build,
and the decoupled core datasource plugins built to their own `dist/`. It serves
on port 3000 behind the sandbox's public HTTPS URL.

Everything is local to the sandbox. There is no external network to speak of and
no other service running.

## Logging in

Grafana requires a login for almost everything.

- URL: `/login`
- Username: `{{ secrets.GRAFANA_ADMIN_USERNAME }}`
- Password: `{{ secrets.GRAFANA_ADMIN_PASSWORD }}`

Those placeholders are substituted at tool-call time from the account secrets
and are fenced to the preview origin. The same two secrets are what the setup
script hands grafana as its admin credentials, so they are always in step. Do
not paste literal credentials into this file or into a scenario.

After login you land on the org home dashboard, which the setup script points at
the seeded dashboard below.

## What is seeded

The setup script provisions this on every boot, so it is always present:

- **A datasource**: `TestData` (uid `aviator-preview-testdata`), set as default.
  It is grafana's built-in generator — it needs no external service.
- **A dashboard**: **Preview Overview** (uid `aviator-preview`) in the
  **Preview** folder, at `/d/aviator-preview`. Four panels: a timeseries, a
  stat, a table, and a text panel.

That dashboard is the fastest way to get real panels on screen. If a change
affects panels, visualisations, the time picker, dashboard chrome or the
navigation, exercise it there.

Anything you create (dashboards, folders, users, alert rules) is written to a
local SQLite database and survives only for the life of the sandbox. Any new
commit on the branch cold-boots a fresh one.

## Useful routes

| Route | What is there |
| --- | --- |
| `/` | Home — the seeded Preview Overview dashboard |
| `/d/aviator-preview` | The seeded dashboard directly |
| `/dashboards` | Dashboard and folder browser |
| `/explore` | Explore, against the TestData datasource |
| `/connections/datasources` | Datasource list, config editors, "Add new" |
| `/alerting/list` | Alert rules, contact points, notification policies |
| `/admin/settings` | The server's effective configuration — good evidence for anything config-driven |
| `/admin/users`, `/admin/orgs` | Server administration |
| `/plugins` | Installed plugins (core only here) |
| `/profile` | User preferences: theme, home dashboard, timezone, language |
| `/swagger` | The HTTP API browser |

## What this preview does NOT exercise

Do not write scenarios against these — they cannot pass here, and a failure is
the environment, not the branch:

- **Other datasources.** Only TestData has data. Prometheus, Loki, MySQL,
  CloudWatch and the rest have no server to talk to. Their *config and query
  editor UI* still opens and can be verified visually; running a query cannot.
- **External network.** Plugin installs from grafana.com, the plugin catalog,
  update checks, the news feed and Gravatar images are unavailable or disabled.
- **Email.** No SMTP, so invites, password resets and email contact points never
  send.
- **Alert delivery.** Rules can be created and evaluated; notifications go
  nowhere, because no contact-point endpoint is reachable.
- **Image rendering.** The renderer plugin is not installed, so panel PNG export
  and "Share → rendered image" fail.
- **Enterprise features.** This is an OSS build: no reporting, no enterprise
  RBAC, no enterprise datasources.
- **SSO.** No OAuth, SAML or LDAP provider is configured — only the local admin
  login above.
- **Performance.** The frontend is an unminified development build with source
  maps. First paint after a cold boot can take 10–20 seconds, and page weight is
  far above production. Never report a performance regression from this
  environment.
- **The database backend.** SQLite only; nothing Postgres- or MySQL-specific.

## Feature-toggled changes

A large share of grafana changes sit behind a feature toggle, and the preview
runs with whatever `pkg/services/featuremgmt/registry.go` sets as the default
(plus `react19`, which the setup script pins).

Before writing scenarios, check whether the code under review is gated. If the
toggle's `Expression` is `"false"`, the change is **not reachable in this
preview** as configured — say so instead of reporting the old behaviour as a
regression. A branch that wants its toggle previewed can add it to
`GF_FEATURE_TOGGLES_ENABLE` in `.aviator/scripts/preview-setup.sh`; the preview
runs that script from the branch, so the change takes effect on the next boot.

## Reading the screen

- Panels load asynchronously. Wait for the panel body to render before
  screenshotting — an in-flight panel shows a header with an empty body, which
  looks like a bug and is not one.
- To force fresh data, use the refresh control or move the time range; the
  TestData random walk changes on every query.
- Grafana surfaces errors as toasts in the top-right corner and inside the panel
  header (a red corner triangle with the query error). Both are worth capturing.
- **"If you're seeing this Grafana has failed to load its application files"**
  means the frontend bundle or its assets manifest is broken. That is a preview
  build failure, not a product defect — report it as such rather than as a
  finding about the branch.
