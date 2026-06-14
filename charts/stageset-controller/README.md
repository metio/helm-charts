<!--
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
-->

# stageset-controller

Deploys the [stageset-controller](https://github.com/metio/flux-stageset-controller)
— a Flux-compatible controller for **ordered, gated, multi-stage deployments**.

```sh
helm upgrade --install stageset-controller oci://ghcr.io/metio/helm-charts/stageset-controller \
  --namespace stageset-system --create-namespace
```

## What it installs

- the controller `Deployment` (PSS-restricted), `ServiceAccount`, and cluster
  RBAC. Apply permissions are **not** granted to the controller — it impersonates
  each `StageSet`'s `spec.serviceAccountName`, so tenant RBAC bounds what a
  StageSet can touch;
- the `StageSet` and `StageInventory` CRDs (`stages.metio.wtf/v1`, kept on
  uninstall via `helm.sh/resource-policy: keep`);
- a validating admission webhook for `StageSet` (TLS self-provisioned by
  default; see below);
- a metrics `Service` (+ opt-in `ServiceMonitor`) and the Flagger stage-gate
  `Service`.

## Key values

| Key | Default | Purpose |
|---|---|---|
| `webhook.certMode` | `self-signed` | `self-signed` (in-pod CA, no prerequisite) or `cert-manager` (needs an issuer). |
| `gate.enabled` | `true` | Expose the Flagger stage-gate endpoint. |
| `rollbackStore.backend` | `none` | `none`, `pvc` (RWX for HA), or `s3` for bit-exact rollbacks. |
| `controller.inventoryMode` | `hybrid` | `entries`, `hybrid`, or `applyset`. |
| `controller.noCrossNamespaceRefs` | `false` | Deny cross-namespace `sourceRef`/`dependsOn`. |
| `replicas.max` (> `min`) | `1` | Renders an HPA + PDB for HA standby replicas. |

The webhook defaults to `self-signed` so the chart installs without cert-manager;
switch to `cert-manager` by setting `webhook.certMode=cert-manager` and
`webhook.certManager.issuerRef.name`.

All keys are validated against `values.schema.json` at install time. See the
[controller docs](https://github.com/metio/flux-stageset-controller) for the
full behaviour behind each flag.
