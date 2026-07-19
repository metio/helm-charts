#!/usr/bin/env bash
# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD
#
# Generate a controller chart's ClusterRoles from its released config/rbac/role.yaml
# (controller-gen output), so the chart's RBAC can never drift from what the binary
# declares it needs — the same vendoring model as the CRDs: fetch at the chart's
# appVersion, gitignore the result, regenerate per run. Only the stageset-controller
# chart is generated; the jaas chart's operator RBAC stays hand-authored.
#
#   hack/vendor-rbac.sh ghcr.io/metio/stageset-controller <version>
#
# The flat role.yaml is split by resource scope: namespaced resources go in the
# tenant ClusterRole (bound per-namespace when controller.watchNamespaces is set),
# cluster-scoped ones in the cluster ClusterRole (always bound cluster-wide, since a
# RoleBinding can't convey a cluster-scoped grant). Scope comes from the vendored
# CRD templates for custom resources and a fixed map for built-in kinds, so a new
# cluster-scoped CRD lands in the right role with no edit here.
#
# validatingwebhookconfigurations is excluded from the split and appended below
# instead: the chart scopes it to the operator's own VWC by resourceNames and only
# in self-signed cert mode, neither of which role.yaml can express.
set -euo pipefail

image="${1:?usage: vendor-rbac.sh <image> <version>}"
version="${2:?usage: vendor-rbac.sh <image> <version>}"

case "$image" in
  ghcr.io/metio/stageset-controller) chart="stageset-controller"; repo="metio/stageset-controller" ;;
  *) exit 0 ;; # RBAC generation is stageset-only; the jaas chart's RBAC is hand-authored.
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
templates="$root/charts/$chart/templates"

role="$(curl -fsSL "https://raw.githubusercontent.com/$repo/$version/config/rbac/role.yaml")"
[ -n "$role" ] || { echo "vendor-rbac: empty role.yaml from $repo@$version" >&2; exit 1; }

# is_cluster_scoped <apiGroup> <resource> — succeeds when the resource is
# cluster-scoped. Subresources (foo/status) inherit their parent's scope. A custom
# resource whose CRD this chart vendors reads its scope from the vendored
# crd-<plural>.yaml (so vendor-crds must run first); every other kind — built-in
# groups and externally-installed CRDs the controller only watches (Flux sources,
# jaas snippets), all namespaced — falls through to the fixed cluster-scoped list,
# defaulting to namespaced.
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
    continue # owned + appended below, scoped and conditional
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
    # sort + comma-join the resources, then space out every comma (paste's -d takes
    # single-char delimiters that would cycle, so ", " must be applied afterwards).
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

{
  header
  cat <<'EOF'
# Tenant-scope ClusterRole: every resource here is namespaced, so when
# controller.watchNamespaces is set this role binds per-namespace via
# rolebinding-tenants.yaml instead of a cluster-wide ClusterRoleBinding. The
# permissions to apply a StageSet's rendered manifests are deliberately absent —
# the controller mints a TokenRequest token for spec.serviceAccountName and writes
# as that SA, so each tenant's own RBAC bounds the apply (no impersonate verb).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "stageset.name" . }}
  labels:
    {{- include "stageset.labels" . | nindent 4 }}
rules:
EOF
  emit_rules tenant
} > "$templates/clusterrole-controller.yaml"

{
  header
  cat <<'EOF'
# Cluster-scope ClusterRole: cluster-scoped resources (namespaces, the cluster-
# scoped CRDs) the controller watches regardless of controller.watchNamespaces, so
# it always binds cluster-wide (clusterrolebinding-cluster.yaml) — a RoleBinding
# cannot convey a cluster-scoped grant.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "stageset.name" . }}-cluster
  labels:
    {{- include "stageset.labels" . | nindent 4 }}
rules:
EOF
  emit_rules cluster
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
} > "$templates/clusterrole-controller-cluster.yaml"

echo "generated clusterrole-controller{,-cluster}.yaml for $chart from $repo/config/rbac/role.yaml@$version"
