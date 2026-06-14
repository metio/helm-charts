<!--
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
 -->

# Jsonnet-as-a-Service (JaaS) Helm Chart

This [Helm chart](https://helm.sh/) defines a minimal JaaS deployment with limited resource usage. See the [values.yaml](./values.yaml) for configuration options.

The chart is published in OCI format and can be downloaded from `oci://ghcr.io/metio/jaas` using `helm`.

Install it with:

```shell
helm install SOME_RELEASE oci://ghcr.io/metio/jaas --version SOME_VERSION
```

Replace `SOME_RELEASE` and `SOME_VERSION` with appropriate values for your environment. In general, we recommend to run the latest available version.

## Usage with grafana-operator

JaaS is intended to be used together with the grafana-operator to manage Grafana dashboards using Jsonnet. However, it can evaluate any kind of Jsonnet, so using it for something else is fine too. See the [official upstream documentation](https://grafana.github.io/grafana-operator/docs/examples/dashboard/jaas/readme/) on how to integrate with the grafana-operator.

## Adding Jsonnet snippets

Once you have your Jsonnet snippets as OCI objects, add them under the `snippets` key in the [values.yaml](./values.yaml) like this:

```yaml
snippets:
  your-dashboard: ghcr.io/your-org/your-repo:some-tag
  other-dashboard: ghcr.io/your-org/other-repo:other-tag
  ...
```

## Adding Jsonnet libraries

Add all libraries similarly under the `additionalLibraries` key like this:

```yaml
additionalLibraries:
  your-library: ghcr.io/your-org/your-library:your-tag
  other-library: ghcr.io/your-org/other-library:other-tag
  ...
```

## Defining external variables

In order to define external variables (`std.extVar`), use the `externalVariables` key like this:

```yaml
externalVariables:
  your-variable: some-value
  other-variable: something-else
```

If you want to load external variables from either a `ConfigMap` or a `Secret` use the `externalVariablesFrom` key like this:

```yaml
externalVariablesFrom:
  configMaps:
    - some-config-map
  secrets:
    - some-secret
```

In order for environment variables to be picked up from `ConfigMaps` or `Secrets` make sure that they start with `JAAS_EXT_VAR_`.

## Operator mode

Setting `operator.enabled: true` switches JaaS into operator mode alongside the HTTP path. The operator watches `JsonnetSnippet` and `JsonnetLibrary` CRDs (`jaas.metio.wtf/v1`) and publishes evaluated results as Flux `ExternalArtifact` resources. CRDs are bundled in `helm/crds/` and installed on first apply. Cluster-shared libraries are mounted via `additionalLibraries` (OCI volumes) rather than a cluster-scoped CR.

```yaml
operator:
  enabled: true
  defaultServiceAccount: jaas-tenant       # SA used when a snippet omits spec.serviceAccountName
  noCrossNamespaceRefs: true               # reject snippets referencing libraries outside their namespace
  extVars:
    cluster: prod                          # operator-level ext-vars; conflicting CR keys are rejected at admission
```

The operator opens a storage HTTP server (default port 8082) that downstream Flux consumers (`kustomize-controller`, `helm-controller`) dereference to fetch the published tarballs. The chart provisions a `Service` named `jaas-storage` for in-cluster routing; override `operator.storage.baseURL` if you front it with an Ingress.

## Validating admission webhook

Setting `operator.webhook.enabled: true` boots a validating webhook that rejects `JsonnetSnippet`s whose `spec.externalVariables` collide with the operator's `extVars`. The chart provisions a `Service` (`jaas-webhook`), a `ValidatingWebhookConfiguration`, and — when `operator.webhook.certManager.enabled: true` — a cert-manager `Certificate` that issues TLS material into the Secret the Deployment mounts.

```yaml
operator:
  enabled: true
  webhook:
    enabled: true
    certManager:
      enabled: true
      issuerRef:
        kind: Issuer        # or ClusterIssuer
        name: jaas-issuer   # must exist in the chart's namespace (Issuer) or cluster (ClusterIssuer)
```

Out-of-band cert provisioning is supported: set `operator.webhook.certManager.enabled: false`, create a Secret matching `operator.webhook.secretName` with `tls.crt` / `tls.key`, and inject the CA bundle into the `ValidatingWebhookConfiguration` yourself.

For clusters without cert-manager, switch to in-pod self-signed certs:

```yaml
operator:
  enabled: true
  webhook:
    enabled: true
    certMode: self-signed
    selfSignedValidity: 8760h   # 1 year; default
```

In this mode the operator generates a CA + serving cert on startup, writes them into an emptyDir mounted at `operator.webhook.certDir`, and patches its own `ValidatingWebhookConfiguration` `caBundle`. A renewer goroutine rotates the cert at `validity/3` and re-patches the caBundle; controller-runtime's `certwatcher` hot-reloads TLS from the new file (fsnotify-driven, no polling lag).

## IPv4 / IPv6 dual-stack

JaaS's HTTP servers (jsonnet, management, storage) default to binding on `::`, the IPv6 wildcard, which on Linux accepts both IPv6 and IPv4-via-mapped-addresses thanks to the default `IPV6_V6ONLY=0`. The webhook and controller-runtime metrics servers already use empty Host fields, so they bind dual-stack out of the box.

Use `service.ipFamilyPolicy` + `service.ipFamilies` to apply the dual-stack contract to every Service the chart renders (jaas / jaas-storage / jaas-webhook / jaas-metrics):

```yaml
service:
  ipFamilyPolicy: RequireDualStack
  ipFamilies: [IPv4, IPv6]
```

On clusters that don't support dual-stack, override the bind addresses back to IPv4:

```yaml
arguments:
  listenAddress: 0.0.0.0
  managementListenAddress: 0.0.0.0
operator:
  storage:
    listenAddress: 0.0.0.0
```

## Notifications via flux notification-controller

The operator emits Kubernetes `Event` objects on every Ready-condition transition: `Normal` for `Synced`, `Warning` for every other reason. Wire them to Slack / Teams / Webhook / etc. via Flux's `notification-controller` `Alert` CRs:

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: jaas-snippet-failures
  namespace: flux-system
spec:
  providerRef:
    name: slack
  eventSeverity: warn
  eventSources:
    - kind: JsonnetSnippet
      name: '*'
```

No JaaS-side configuration is needed — the chart ships the `RBAC` the operator needs to emit events.

## Pause + revision history

- `spec.suspend: true` on a `JsonnetSnippet` pauses reconciliation. The previous artifact is left in place — downstream Flux consumers keep serving it. Setting `suspend: false` (or removing the field) resumes.
- `spec.history` (default `1`, max `50`) keeps the last N revisions in storage so downstream consumers can pin to a historical sha256. Status reports `status.history: [{revision, time}]`.
- `spec.interval` (optional `<duration>`, e.g. `10m`) re-renders the snippet on a cadence even when no watch event fires. Picks up env-var drift, OCI library refreshes, and any other state outside the watched object graph.
- `spec.entryFile` (default `main.jsonnet`) names the file go-jsonnet evaluates. Lets a snippet point at a specific file inside a multi-snippet source tree.

## Pod Security Standards

Both pods the chart renders — the jaas Deployment and the pre-delete cleanup Job — are configured for **Pod Security Standards "restricted"**:

- container-level `securityContext`: `runAsNonRoot`, `runAsUser`/`runAsGroup` non-zero, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`
- pod-level `securityContext` mirrors `runAsNonRoot` + `seccompProfile`, so admission rejects any future sidecar that doesn't match
- only PSS-allowed volume types: `configMap`, `emptyDir`, `secret`, `persistentVolumeClaim`, `projected`, and `image:` (OCI artifact volumes for snippet/library mounts — restricted-compliant from Kubernetes 1.33 onward)

If you'd like the chart to also render its install namespace with the matching admission labels, opt in:

```yaml
namespace:
  create: true
  podSecurity:
    enforce: restricted
    audit: restricted
    warn: restricted
```

On clusters older than Kubernetes 1.33, drop `enforce` to `baseline` — `image:` volumes weren't on the restricted allow-list until 1.33.

## Uninstall hygiene

`helm uninstall` runs a `pre-delete` Job that bulk-deletes every `JsonnetSnippet` cluster-wide so the operator's finalizer drops the published `ExternalArtifact` + tarball BEFORE the operator pod is removed. Without this, downstream Flux consumers would be left referencing orphaned artifacts.

Disable the hook only when uninstall is driven by a tool that strips Helm hooks (e.g., ArgoCD with hooks off):

```yaml
operator:
  cleanupOnDelete:
    enabled: false
```

…and clean up manually:

```shell
kubectl delete jsonnetsnippet --all -A --wait=true --timeout=2m
helm uninstall jaas -n <ns>
```

If the operator pod is already dead when the hook runs, the Job times out (default 2 minutes), strips finalizers, and proceeds so Helm doesn't hang forever.

**PVC isn't deleted** — Helm intentionally leaves PVCs behind. To reclaim the storage volume, `kubectl delete pvc <release>-storage -n <ns>` after `helm uninstall`. With `backend: s3` the bucket and its objects are external; jaas only cleans up its own keys via the per-snippet finalizer.
