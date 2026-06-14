<!--
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
-->

# joi

Installs [Jsonnet-OCI-Images](https://github.com/metio/jsonnet-oci-images) (JOI)
as in-cluster JaaS libraries: for each image, the chart renders a Flux
`OCIRepository` and a JaaS `JsonnetLibrary` that sources it. Snippets then import
them with the **exact jb vendor path used during local development** — e.g.
`import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet'`. The
operator resolves relative and absolute imports like `jsonnet -J vendor`, so
real jb-vendored libraries (grafonnet, docsonnet, xtd) render identically
locally and in-cluster.

```sh
helm upgrade --install joi oci://ghcr.io/metio/helm-charts/joi \
  --namespace my-tenant
```

## Requirements

- Flux **source-controller** (provides the `OCIRepository` CRD and pulls the artifacts).
- **JaaS in operator mode** (`operator.enabled=true` on the `jaas` chart — provides the `JsonnetLibrary` CRD + reconciler).

The JOI images are single-layer, so the `OCIRepository` needs no `layerSelector`
(source-controller extracts the one layer). This is the Flux/CR counterpart to
mounting the same images as static OCI volumes via the `jaas` chart's
`additionalLibraries` — the two modes are mutually exclusive per release.

## Configuration

| Key | Default | Purpose |
|---|---|---|
| `libraries` | grafonnet, docsonnet, xtd | Map of `<alias>: {enabled, image, tag, path}`. The key is the JsonnetLibrary name and import alias. Add your own entries. |
| `registryMirror` | `""` | Rewrites every image's registry host (e.g. `registry.internal:5000`) for air-gapped clusters. |
| `imagePullSecret` | `""` | dockerconfigjson Secret for authenticated (private-mirror) pulls. |
| `interval` | `60m` | OCIRepository re-pull cadence; per-library override via `libraries.<name>.interval`. |
| `namespace` | release ns | Where the objects (and thus the import aliases) live. |

### Adding a library

Add an entry to `libraries` mirroring a `jsonnet-oci-images` image:

```yaml
libraries:
  myorg-mylib:
    enabled: true
    image: ghcr.io/metio/joi-myorg-mylib
    tag: latest
    path: ""   # whole vendor tree; import via the full github.com/... path
```

