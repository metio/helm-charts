{{- /*
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
*/ -}}

{{- /* Namespace the JOI objects land in (release namespace by default). */ -}}
{{- define "joi.namespace" -}}
{{- .Values.namespace | default .Release.Namespace -}}
{{- end -}}

{{- /* Effective image ref: swaps the registry host for the mirror when set.
       Input dict: {image, mirror}. The leading registry segment (up to the
       first slash) is replaced, so ghcr.io/metio/joi-x -> <mirror>/metio/joi-x. */ -}}
{{- define "joi.image" -}}
{{- if .mirror -}}
{{- printf "%s/%s" .mirror (regexReplaceAll "^[^/]+/" .image "") -}}
{{- else -}}
{{- .image -}}
{{- end -}}
{{- end -}}

{{- /* Space-separated, sorted set of libraries to actually render: every
       enabled library plus the transitive dependency `closure` of each (so
       enabling grafonnet auto-renders xtd, and anything xtd itself requires).
       A dep is only pulled in if it has its own entry in .Values.libraries.

       The closure is resolved to a fixpoint rather than one level deep:
       templates have no while-loop, so iterate len(libraries) times — the
       longest possible dependency chain visits each library at most once, so
       that many passes always converges. Each pass folds in the closures of
       everything currently in the set; new entries are picked up on the next
       pass. */ -}}
{{- define "joi.effectiveNames" -}}
{{- $libs := .Values.libraries -}}
{{- $set := dict -}}
{{- range $name, $lib := $libs -}}
{{- if $lib.enabled -}}{{- $_ := set $set $name true -}}{{- end -}}
{{- end -}}
{{- range $pass := until (len $libs) -}}
{{- range $name := (keys $set) -}}
{{- range $dep := ((index $libs $name).closure | default list) -}}
{{- if hasKey $libs $dep -}}{{- $_ := set $set $dep true -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- keys $set | sortAlpha | join " " -}}
{{- end -}}

{{- /* Common metadata labels. */ -}}
{{- define "joi.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}
