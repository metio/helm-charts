<!--
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
-->

# helm-charts repository design

> Status: draft for review. Licensed **0BSD** (the metio-wide convention).

## Purpose

A single repository holding every metio Helm chart — initially `jaas` and
`stageset-controller`, both Flux-style controllers — with one set of
verification and release pipelines. It replaces the per-project `helm/`
directories (jaas's chart moves here; the stageset-controller chart is authored
here from the start).

The guiding split: **source repos build and publish container images; this repo
builds and publishes charts.** A chart here references an image by version; it
never builds one. The two are versioned and released independently.

## Repository layout

```text
charts/
  common/                     # library chart (type: library) — shared template helpers
    Chart.yaml
    templates/_*.tpl
  jaas/
    Chart.yaml                # appVersion = deployed image version; dependency on common
    values.yaml               # with # @schema annotations
    values.schema.json        # generated from values.yaml, drift-gated
    templates/
    tests/                    # helm-unittest (+ __snapshot__/)
    crds/  or templates/crd-*.yaml   # vendored from the source repo (see CRD provenance)
    README.md
    MIGRATIONS.md             # per-chart breaking-change notes, linked from each release
  stageset-controller/
    ... (same shape)
ct.yaml                       # chart-testing config
renovate.json                 # image/appVersion bump automation
dev/Containerfile             # dev-shell tools (helm, ct, helm-unittest, helm-schema, kube-score, kubeconform, yamllint, …)
.ilo.rc                       # ilo dev-shell args (not committed; per-machine)
docs/design.md                # this document
docs/decisions/               # ADRs for notable choices
.github/workflows/{verify,release,bump}.yml
LICENSE / REUSE.toml          # 0BSD
```

`charts/<name>/` is the de-facto standard monorepo layout (chart-testing,
chart-releaser, and Renovate all key off it).

### The `common` library chart

jaas and stageset-controller are near-identical Flux controllers: both ship a
Deployment (PSS-restricted securityContext, probes, resources, topology
spread), a ServiceAccount + ClusterRole/Role with the `--watch-namespaces`
RBAC pivot, a validating webhook (cert-manager **and** self-signed modes, VWC,
Service), a metrics Service + opt-in ServiceMonitor + PrometheusRule, an opt-in
NetworkPolicy, a namespace with Pod-Security labels, and HPA/PDB gated on
`replicas.max > replicas.min`. That is a lot of identical YAML.

**Decision:** factor the shared scaffold into a `common` **library chart**
(`type: library`) exposing named templates (`metio-common.deployment`,
`.rbac`, `.webhook`, `.serviceMonitor`, `.prometheusRule`, `.networkPolicy`,
`.namespace`, `.labels`, …). Each application chart depends on it via a local
`file://../common` dependency (vendored with `helm dependency build`, never
separately published) and supplies only its specifics — jaas's storage PVC,
cleanup Job, OCI library volumes; stageset-controller's gate endpoint and
rollback-store flags; each one's CRDs.

**Adoption is phased** to de-risk:

1. **Move charts in as-is.** Relocate jaas's `helm/` to `charts/jaas/`
   unchanged; author `charts/stageset-controller/` from the controller's
   existing manifests + the design doc. Get CI/release green on independent
   charts first.
2. **Extract `common`.** Once both charts are here and their duplication is
   visible, lift the shared templates into `common` and refactor both to use
   it. helm-unittest snapshots make this refactor safe (rendered output must
   not change).

If the duplication proves smaller than expected, charts may stay independent —
the library chart is a strong default, not a hard requirement.

## Versioning

Two version fields, decoupled (Helm best practice, and necessary here because
the image is built in another repo):

- **Chart `version`** — the chart's own version,
  **`%Y.%-m.%-d+%H%M%S`** (e.g. `2026.6.16+142305`), stamped at release time,
  **per chart, only when that chart changed**. The committed `Chart.yaml` keeps
  a `0.0.0` placeholder; the release pipeline rewrites it. The
  `%Y.%-m.%-d` core is the metio calendar version (day granularity, sorts
  correctly across days); the `+%H%M%S` is **SemVer build metadata** giving each
  release a unique identity down to the second — comfortably past the
  "multiple releases per day, ≥1/minute" requirement.

  Why build metadata rather than a fourth segment or time-in-`PATCH`: Helm
  enforces SemVer 2.0.0, which is exactly three numeric segments and forbids
  leading zeros in them — so `2026.6.16.1423` is invalid (four segments) and a
  `PATCH` like `0905` (09:05) is invalid (leading zero). Build metadata has
  neither restriction, is valid SemVer, and Helm renders it into the OCI tag by
  replacing `+` with `_` (`2026.6.16_142305`), so each release is a distinct,
  pullable artifact. Build metadata is ignored for SemVer precedence, which is
  irrelevant for OCI (artifacts are addressed by exact tag, not range-resolved
  through a `helm repo index`).
- **Chart `appVersion`** — the controller image version the chart deploys
  (also calendar, e.g. `2026.6.16`). **Committed** in `Chart.yaml` (it is
  meaningful state: "this chart deploys image X") and bumped by automation when
  the source repo publishes a new image. `image.tag` in `values.yaml` defaults
  to `.Chart.AppVersion`, so bumping `appVersion` moves the deployed image.

This differs from jaas's current lockstep (where chart `version == appVersion ==`
release-day date) because the image no longer releases from the same repo on the
same run. A chart is re-released when its templates change **or** its
`appVersion` advances; a quiet week releases nothing.

The `common` library chart is versioned the same way but, being a `file://`
dependency, is never pushed — consuming charts vendor it at build time.

Per-second build metadata makes same-day (indeed same-minute) re-releases
distinct artifacts, so no collision guard is needed; two releases of one chart
in the same second is not reachable from event-driven CI.

## CRD provenance

Both charts ship CRDs, but CRDs are generated in the **source** repos
(`controller-gen` → `config/crd/bases`). With the chart split out, the chart's
CRDs must stay in lockstep with the image they pair with.

**Decision:** CRDs are **vendored** into the chart and updated by the same
automation that bumps `appVersion` — the bump PR copies the source repo's
`config/crd/bases/*.yaml` (at the released tag) into the chart, preserving the
`helm.sh/resource-policy: keep` annotation, so CRDs and image move together. A
verification step asserts the vendored CRDs match the source repo's tag for the
pinned `appVersion` (the analogue of jaas's existing CRD-sync gate, now
cross-repo). CRDs live under `templates/crd-*.yaml` (not `crds/`) so
`helm upgrade` applies schema changes — matching jaas's deliberate choice.

## Image-version updates (and testing them)

When jaas or stageset-controller publishes a new weekly image, the matching
chart needs its `appVersion` (+ vendored CRDs) bumped and re-tested.

**Decision: Renovate** watches `ghcr.io/metio/jaas` and
`ghcr.io/metio/stageset-controller` (and the OCI library images jaas mounts
via `additionalLibraries`) and opens a PR per bump:

- updates `appVersion` in `Chart.yaml` (regex/custom manager),
- re-vendors that release's CRDs (a Renovate `postUpgradeTasks` hook, or a small
  workflow the PR triggers),
- which runs the **full verification suite** below — crucially `ct install`
  into a kind cluster with the **new** image, so a chart that can't deploy the
  new controller fails the PR before release.

Renovate (no cross-repo tokens) is preferred over a `repository_dispatch` from
the source release; dispatch is the fallback if tighter coupling is wanted.

The deep controller behaviour is still covered by each source repo's own
`kind-smoke` (it tests the binary). Here the install test answers a different
question — *does the chart deploy this image cleanly and come up Ready* — so the
two don't duplicate.

## Verification CI (`verify.yml`, PR gate)

Runs only against **changed charts** (chart-testing detects them via git diff
to the base). Mirrors the metio tool set so charts lint the same way the code
does:

- **`ct lint`** — Chart.yaml validity, maintainers, and (importantly) that the
  chart `version` was bumped when templates changed.
- **`helm-unittest`** — the per-template assertions + snapshots jaas already
  has; ported as-is.
- **helm-schema drift gate** — regenerate `values.schema.json` from
  `values.yaml` `# @schema` annotations, fail on any diff (jaas's gate).
- **kube-score** — render each chart under representative value combinations
  (default / operator / webhook-self-signed / persistence / networkpolicy) and
  fail on CRITICAL, with `kube-score/ignore` for deliberate choices (jaas's
  gate).
- **kubeconform** — validate rendered manifests (incl. the chart's CRDs) against
  Kubernetes + CRD schemas.
- **CRD-sync gate** — vendored CRDs match the source repo's tag for `appVersion`.
- **`ct install`** — spin up kind, install cert-manager + Flux source-controller
  (for the `ExternalArtifact` CRD both charts integrate with), install each
  changed chart, wait for Ready. This is where a bad image bump is caught. Each
  chart's install variants come from its `ci/*-values.yaml` files (the
  chart-testing convention) — the same files `kube-score` renders, so one set of
  value combinations feeds both gates. **Precondition:** the install pulls
  `ghcr.io/metio/<image>:<appVersion>`, so the matching controller image must
  already be published; until a source repo cuts its first image, that chart's
  `appVersion` stays at the `0.0.0` placeholder and its install job cannot go
  green.
- **Text linters** — `yamllint`, `markdownlint`, `typos`, and **REUSE** — the
  same configs the projects use, kept identical across repos.

### Kubernetes version matrix (dynamic)

The `ct install` job runs against several Kubernetes versions, and the list is
**computed at CI time**, not hardcoded: a setup job queries the `kindest/node`
Docker tags, derives the latest patch of the newest N minors (default 4), and
emits JSON the install matrix consumes via `fromJSON`. The day
`kindest/node:v1.37.0` ships it enters the matrix automatically; `1.36.2` is
replaced by `1.36.3` with no edit. `kindest/node` is the datasource (not
`kubernetes/kubernetes`) because kind is what constrains which versions are
actually installable.

This is deliberate over a Renovate-maintained list: Renovate *freshens* existing
entries but cannot *grow* a list, so it can't auto-add a new minor. The trade-off
is that the matrix can change without a reviewed PR. A repo wanting PR-gated,
reproducible matrices can instead hardcode the list and add a Renovate regex
manager with per-minor `allowedVersions` `packageRules` to patch-bump each entry
— at the cost of a manual row-add per new minor.

## Release CI (`release.yml`)

**Event-driven, per changed chart** (not the source repos' weekly cron): a chart
repo changes in discrete PRs (a template edit, an `appVersion` bump), so
releasing exactly when a chart changes is cleaner than a fixed cadence. Trigger
on push to `main` touching `charts/**` (+ `workflow_dispatch`).

For each chart whose content changed since its last release:

1. `helm dependency build` (vendors `common`).
2. `helm package charts/<name> --version "$(date +'%Y.%-m.%-d+%H%M%S')" --app-version <appVersion>`.
3. `helm push <name>-<version>.tgz oci://ghcr.io/metio/helm-charts` — charts live
   under a dedicated **`helm-charts/` namespace**: `oci://ghcr.io/metio/helm-charts/jaas`,
   `oci://ghcr.io/metio/helm-charts/stageset-controller`. This is a deliberate move
   off jaas's current `oci://ghcr.io/metio/jaas` (one of the reasons for the new
   repo): it cleanly separates chart artifacts from image artifacts and groups
   all charts under one prefix.
4. **cosign** sign the pushed chart (keyless/OIDC), matching jaas's release-signing posture.
5. Tag the commit `<chart>-<version>` (e.g. `jaas-2026.6.16+142305`) and cut a
   GitHub Release on that tag, with a body generated per the **Release notes**
   section below.

Unchanged charts are skipped. `common` is never pushed.

## Release notes

GitHub's native auto-generated notes diff two tags and list every merged PR
between them with **no path filter** — so in a monorepo a
`stageset-controller` PR would land in `jaas`'s release notes. There is no API
knob to scope it by path, so the native generator cannot be used here.

**Decision: per-chart tags + path-scoped generation.**

- **Per-chart tags define the release boundary.** Each release is tagged
  `<chart>-<version>`. "Changes to this chart since its last release" is then
  the commit range `<chart>-<prev>..HEAD` — a well-defined, per-chart window the
  native generator's single shared tag-line cannot express.
- **Notes are scoped to the chart's path.** The release workflow runs
  [`git-cliff`](https://git-cliff.org) with
  `--include-path "charts/<name>/**"` over that range, so only commits touching
  *this* chart appear. The output becomes the GitHub Release body
  (`gh release create <chart>-<version> --notes-file …`). git-cliff degrades to
  a flat commit list without conventional commits and categorizes
  automatically if they are later adopted (which does not conflict with calendar
  versioning — the version still comes from the date, the commit type only
  drives section headings).

**Every release body also carries a static footer** (appended after the
git-cliff output, identical shape for every release bar the substituted chart +
version):

- **cosign verification instructions** — the exact command to verify the signed
  OCI artifact this release published, so a consumer can confirm provenance
  before `helm install`:

  ```sh
  cosign verify ghcr.io/metio/helm-charts/<name>:<version> \
    --certificate-identity-regexp '^https://github.com/metio/helm-charts/\.github/workflows/release\.yml@refs/' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
  ```

  `<version>` here is the **OCI tag form** — Helm renders the chart `version`'s
  `+` as `_`, so `2026.6.16+142305` is pulled and verified as
  `2026.6.16_142305`. The signature is keyless (Fulcio/Rekor), so verification
  needs no public key, only the workflow identity + OIDC issuer above.
- **A link to the chart's migration notes** —
  `charts/<name>/MIGRATIONS.md`, anchored at this version's heading (e.g.
  `…/charts/jaas/MIGRATIONS.md#2026616`). Operators read it before upgrading;
  releases with no breaking change still link it (the file simply has no entry
  for that version).

**Migration notes live per chart** in `charts/<name>/MIGRATIONS.md`, following
the metio convention: a level-1 heading per chart version, body written as
state-of-the-world for an operator ("the X label has moved", "re-point your
`HelmRepository` source"), naming the commands a naive `helm upgrade` needs and
any user-visible side effect. Unlike a `CHANGELOG.md`, this file is **authored
by hand in the same PR as the breaking change**, not written back by CI, so it
does not cause a release loop. (The jaas chart's first entry here is the OCI
path move — `oci://ghcr.io/metio/jaas` → `oci://ghcr.io/metio/helm-charts/jaas`.)

**No committed `CHANGELOG.md`.** The per-chart GitHub Releases — filterable by
the `<chart>-*` tag prefix — *are* the browsable changelog. A committed
changelog is deliberately avoided: writing it back from CI would touch
`charts/<name>/**` and re-trigger the event-driven release, looping.

**No `artifacthub.io/changes` annotation.** That annotation only pays off when
charts are listed on Artifact Hub (they are not) and needs categorized,
curated entries to be worth maintaining. It is intentionally omitted; the
GitHub Release is the single source of release notes. (If the charts are ever
published to Artifact Hub, revisit — git-cliff can emit the annotation block
from the same range in one run.)

## Dev shell

Same `ilo` pattern as the other repos: a `dev/Containerfile` bundling `helm`,
the `helm-unittest` plugin, `chart-testing` (`ct`), `helm-schema`, `kube-score`,
`kubeconform`, `cosign`, `git-cliff`, `yamllint`, `markdownlint`, and `typos`; a
per-machine `.ilo.rc` (git-ignored) so `ilo bash -c 'ct lint --all'` works
locally exactly as in CI. No host toolchain required.

## Migration plan

1. Scaffold the repo: `dev/Containerfile`, `.ilo.rc`, `ct.yaml`, `renovate.json`,
   `LICENSE`/`REUSE.toml` (0BSD), the three workflows, this doc.
2. Move jaas's `helm/` → `charts/jaas/` verbatim (history-preserving move);
   delete `jaas/helm/`, its chart publish step, and its chart CI from the jaas
   repo. **Breaking for chart consumers:** new jaas chart releases publish to
   `oci://ghcr.io/metio/helm-charts/jaas`, not `oci://ghcr.io/metio/jaas`. Existing
   versions remain pullable at the old path, but new ones do not land there —
   record the new URL as the first entry in `charts/jaas/MIGRATIONS.md` and in
   the chart README so users repoint their `helm`/Flux `HelmRepository` source.
3. Author `charts/stageset-controller/` from the controller's `config/` + design
   doc (Deployment, RBAC, webhook with cert-manager/self-signed, metrics,
   NetworkPolicy, CRDs, gate endpoint, rollback-store knobs).
4. Wire Renovate for both images; confirm the first auto-bump PR goes green
   through `ct install`.
5. (Later) extract the `common` library chart and refactor both charts onto it,
   guarded by the unittest snapshots.

## Decisions settled

- **License/copyright**: 0BSD, "The helm-charts Authors".
- **Chart OCI path**: `oci://ghcr.io/metio/helm-charts/<name>` (moved off
  `oci://ghcr.io/metio/jaas`; breaking for jaas chart users — migration note
  above).
- **Release trigger**: event-driven on merge to `main` touching `charts/**`.
- **Versioning**: chart `version` = `%Y.%-m.%-d+%H%M%S` (build-metadata time,
  multiple releases/day); `appVersion` = the image's `%Y.%-m.%-d`.
- **Release notes**: per-chart tags `<chart>-<version>` + `git-cliff
  --include-path "charts/<name>/**"` generate each GitHub Release body, with a
  static footer carrying cosign-verify instructions and a link to
  `charts/<name>/MIGRATIONS.md`. No committed `CHANGELOG.md`, no
  `artifacthub.io/changes` annotation.

## Still open

- **`common` library chart now or after the move?** Recommended: after — move
  both charts in as-is first, extract once duplication is visible.
- **Image bumps via Renovate vs `repository_dispatch`** — Renovate recommended
  (no cross-repo tokens).
