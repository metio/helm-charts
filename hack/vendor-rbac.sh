#!/usr/bin/env bash
# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD
#
# Generate a controller chart's ClusterRoles from its released config/rbac/role.yaml
# (controller-gen output), so the chart's RBAC can never drift from what the binary
# declares it needs — the same vendoring model as the CRDs: fetch at the chart's
# appVersion, gitignore the result, regenerate per run.
#
#   hack/vendor-rbac.sh ghcr.io/metio/stageset-controller <version>
#   hack/vendor-rbac.sh ghcr.io/metio/jaas <version>
#
# The flat role.yaml is split by resource scope: namespaced resources go in the
# tenant ClusterRole (bound per-namespace when the chart scopes its watches),
# cluster-scoped ones in the cluster ClusterRole (always bound cluster-wide, since a
# RoleBinding can't convey a cluster-scoped grant). Scope comes from the vendored CRD
# templates for custom resources and a fixed map for built-in kinds, so a new
# cluster-scoped CRD lands in the right role with no edit here.
#
# validatingwebhookconfigurations is excluded from the split and appended by
# vwc_block instead: the chart scopes it to the operator's own VWC by resourceNames
# and only in self-signed cert mode, neither of which role.yaml can express. Each
# chart's leader-election Role (coordination.k8s.io/leases) stays hand-authored —
# controller-gen's flat ClusterRole cannot express a namespaced Role.
set -euo pipefail

image="${1:?usage: vendor-rbac.sh <image> <version>}"
version="${2:?usage: vendor-rbac.sh <image> <version>}"

root="$(cd "$(dirname "$0")/.." && pwd)"

# Per-chart scaffolding: role names + files (which the bindings reference), the
# labels block, any enclosing render gate, and the chart's VWC rule.
case "$image" in
  ghcr.io/metio/stageset-controller)
    chart="stageset-controller"; repo="metio/stageset-controller"
    tenant_file="clusterrole-controller.yaml"; cluster_file="clusterrole-controller-cluster.yaml"
    tenant_name='{{ include "stageset.name" . }}'
    cluster_name='{{ include "stageset.name" . }}-cluster'
    gate_open=""; gate_close=""
    labels() { printf '  labels:\n    {{- include "stageset.labels" . | nindent 4 }}\n'; }
    vwc_block() {
      cat <<'EOF'
{{- if and .Values.webhook.enabled (eq .Values.webhook.certMode "self-signed") }}
  # The self-signed cert provisioner patches its own ValidatingWebhookConfiguration's
  # caBundle in-pod. Scoped to that named VWC by resourceNames (which role.yaml can't
  # express) and needed only in this cert mode, so it is owned here, not generated.
  - apiGroups: [admissionregistration.k8s.io]
    resources: [validatingwebhookconfigurations]
    resourceNames:
      - {{ include "stageset.name" . }}-{{ include "stageset.namespace" . }}
    verbs: [get, update]
{{- end }}
EOF
    }
    ;;
  ghcr.io/metio/jaas)
    chart="jaas"; repo="metio/jaas"
    tenant_file="clusterrole-operator.yaml"; cluster_file="clusterrole-operator-cluster.yaml"
    tenant_name='{{ .Release.Name }}-operator-tenants'
    cluster_name='{{ .Release.Name }}-operator-cluster'
    gate_open='{{- if and .Values.operator.enabled .Values.operator.rbac.create -}}'
    gate_close='{{- end }}'
    labels() {
      cat <<'EOF'
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/component: operator
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
    app.kubernetes.io/part-of: {{ .Chart.Name }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
    helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
EOF
    }
    vwc_block() {
      cat <<'EOF'
{{- if and .Values.operator.webhook.enabled (eq .Values.operator.webhook.certMode "self-signed") }}
  # Self-signed webhook mode: the operator stamps its own VWC's caBundle. Scoped to
  # that named VWC by resourceNames (which role.yaml can't express) and needed only
  # in this cert mode, so it is owned here, not generated.
  - apiGroups: [admissionregistration.k8s.io]
    resources: [validatingwebhookconfigurations]
    resourceNames:
      - {{ .Release.Name }}-jsonnetsnippet
    verbs: [get, update]
{{- end }}
EOF
    }
    ;;
  *) exit 0 ;; # RBAC generation only for the controller charts above.
esac

templates="$root/charts/$chart/templates"

role="$(curl -fsSL "https://raw.githubusercontent.com/$repo/$version/config/rbac/role.yaml")"
[ -n "$role" ] || { echo "vendor-rbac: empty role.yaml from $repo@$version" >&2; exit 1; }

# is_cluster_scoped <apiGroup> <resource> — succeeds when the resource is
# cluster-scoped. Subresources (foo/status) inherit their parent's scope. A custom
# resource whose CRD this chart vendors reads its scope from the vendored
# crd-<plural>.yaml (so vendor-crds must run first); every other kind — built-in
# groups and externally-installed CRDs the controller only watches (Flux sources),
# all namespaced — falls through to the fixed cluster-scoped list, defaulting to
# namespaced.
is_cluster_scoped() {
  local grp=$1 base=${2%%/*}
  local crd="$templates/crd-$base.yaml"
  if [ -f "$crd" ]; then
    grep -qE '^\s*scope:\s*Cluster\s*$' "$crd"
    return
  fi
  case "$grp" in
    "")
      case "$base" in namespaces | nodes | persistentvolumes) return 0 ;; *) return 1 ;; esac ;;
    admissionregistration.k8s.io | apiextensions.k8s.io) return 0 ;;
    rbac.authorization.k8s.io)
      case "$base" in clusterroles | clusterrolebindings) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# Split every (apiGroup × resource) into scope buckets keyed by "group|verbs", so
# resources sharing an apiGroup and verb set collapse back into one rule.
declare -A tenant cluster
# The yq expression's $g/$r are yq variables, not shell — they must stay single-quoted.
# shellcheck disable=SC2016
entries="$(printf '%s\n' "$role" | yq -r '.rules[] | .apiGroups[] as $g | .resources[] as $r | ($g + "|" + $r + "|" + (.verbs | join(",")))')"
while IFS='|' read -r grp res verbs; do
  [ -n "$res" ] || continue
  if [ "$grp" = "admissionregistration.k8s.io" ] && [ "${res%%/*}" = "validatingwebhookconfigurations" ]; then
    continue # owned + appended by vwc_block, scoped and conditional
  fi
  key="${grp}|${verbs}"
  if is_cluster_scoped "$grp" "$res"; then
    cluster[$key]="${cluster[$key]:+${cluster[$key]} }$res"
  else
    tenant[$key]="${tenant[$key]:+${tenant[$key]} }$res"
  fi
done <<< "$entries"

# emit_rules <assoc-array-name> — one rule per "group|verbs" key, resources and keys
# sorted so the output is deterministic (a stable file across regenerations).
emit_rules() {
  local -n bucket=$1
  local key grp verbs res
  for key in $(printf '%s\n' "${!bucket[@]}" | sort); do
    grp="${key%%|*}"; verbs="${key#*|}"
    [ -n "$grp" ] || grp='""'
    res="$(echo "${bucket[$key]}" | tr ' ' '\n' | sort | paste -sd, -)"
    printf '  - apiGroups: [%s]\n' "$grp"
    printf '    resources: [%s]\n' "${res//,/, }"
    printf '    verbs: [%s]\n' "${verbs//,/, }"
  done
}

header() {
  cat <<'EOF'
{{- /*
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
GENERATED from the controller's config/rbac/role.yaml at the chart's appVersion by
hack/vendor-rbac.sh — do NOT edit. To change a grant, edit the +kubebuilder:rbac
markers in the source repo; this file (gitignored, regenerated per run) then tracks
the release automatically, so the chart's RBAC can never drift from the binary's.
*/ -}}
EOF
}

# render_role <name> <comment> <bucket-array> [append-vwc] — one gitignored ClusterRole
# template: header, optional render gate, metadata, labels, the generated rules, and
# (for the cluster role) the chart's conditional VWC rule.
render_role() {
  local name=$1 comment=$2 bucket=$3 append_vwc=${4:-}
  header
  [ -n "$gate_open" ] && printf '%s\n' "$gate_open"
  printf '# %s\n' "$comment"
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRole\nmetadata:\n  name: %s\n' "$name"
  labels
  printf 'rules:\n'
  emit_rules "$bucket"
  [ -n "$append_vwc" ] && vwc_block
  [ -n "$gate_close" ] && printf '%s\n' "$gate_close"
  # A trailing `[ -n "" ]` (empty gate/vwc) returns 1; without this the function's
  # non-zero return would trip `set -e` at the top-level `render_role > file` call.
  return 0
}

render_role "$tenant_name" \
  "Tenant-scope ClusterRole: namespaced resources, bound per-namespace when the chart scopes its watches (else cluster-wide). Rendered-manifest/apply permissions are deliberately absent — writes run as each tenant's own ServiceAccount." \
  tenant > "$templates/$tenant_file"

render_role "$cluster_name" \
  "Cluster-scope ClusterRole: cluster-scoped resources (CRDs, namespaces) the operator watches regardless of watch scope, so it always binds cluster-wide — a RoleBinding cannot convey a cluster-scoped grant." \
  cluster append-vwc > "$templates/$cluster_file"

echo "generated $tenant_file + $cluster_file for $chart from $repo/config/rbac/role.yaml@$version"
