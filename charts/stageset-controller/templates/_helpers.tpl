{{- /*
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
*/ -}}

{{- /* Fully-qualified resource name. */ -}}
{{- define "stageset.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- /* The image reference, registry/repository:tag (tag defaults to appVersion). */ -}}
{{- define "stageset.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository $tag -}}
{{- end -}}

{{- /* Common metadata labels (includes version-bound labels). */ -}}
{{- define "stageset.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/component: controller
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- /* Immutable selector labels. Deliberately omits version-bound and
       managed-by labels (a Deployment/Service/PDB selector is immutable, so a
       helm upgrade that changes them would fail with "field is immutable"). */ -}}
{{- define "stageset.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/component: controller
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
{{- end -}}

{{- /* The namespace the webhook Service lives in (and the controller's own ns). */ -}}
{{- define "stageset.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{- /* Whether HPA/PDB should render (multi-replica installs only). */ -}}
{{- define "stageset.scaling" -}}
{{- if gt (.Values.replicas.max | int) (.Values.replicas.min | int) -}}true{{- end -}}
{{- end -}}
