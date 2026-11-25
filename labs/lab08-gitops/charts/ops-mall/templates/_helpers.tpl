{{/*
公共标签。课程约定：app.kubernetes.io/name 是组件名，app.kubernetes.io/part-of 固定 ops-mall
*/}}
{{- define "ops-mall.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: ops-mall
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
ops-mall/environment: {{ .root.Values.environment | quote }}
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
选择器标签：一旦创建就不能改，所以只放稳定不变的两个
*/}}
{{- define "ops-mall.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{/*
Pod 模板上的标签：不放 helm.sh/chart，避免只升级 Chart 版本就触发所有 Pod 重建
*/}}
{{- define "ops-mall.podLabels" -}}
{{ include "ops-mall.selectorLabels" . }}
app.kubernetes.io/part-of: ops-mall
ops-mall/environment: {{ .root.Values.environment | quote }}
{{- end -}}

{{- define "ops-mall.image" -}}
{{ printf "%s:%s" .repository (toString .tag) }}
{{- end -}}

{{/*
按节点打散
*/}}
{{- define "ops-mall.spread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        {{- include "ops-mall.selectorLabels" . | nindent 8 }}
{{- end -}}

{{/*
mall-api 的 Pod 模板，Deployment 和 Rollout 共用
*/}}
{{- define "ops-mall.api.podTemplate" -}}
{{- $api := .Values.api -}}
{{- $ctx := dict "root" . "name" $api.name -}}
metadata:
  labels:
    {{- include "ops-mall.podLabels" $ctx | nindent 4 }}
  annotations:
    # ConfigMap 变了 Pod 跟着滚动，否则改了配置也不生效
    checksum/config: {{ include (print $.Template.BasePath "/api-configmap.yaml") . | sha256sum }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  terminationGracePeriodSeconds: {{ $api.terminationGracePeriodSeconds }}
  {{- with $api.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if $api.spreadAcrossNodes }}
  {{- include "ops-mall.spread" $ctx | nindent 2 }}
  {{- end }}
  containers:
    - name: {{ $api.name }}
      image: {{ include "ops-mall.image" $api.image }}
      imagePullPolicy: {{ $api.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ $api.containerPort }}
          protocol: TCP
      envFrom:
        - configMapRef:
            name: {{ $api.name }}-config
        - secretRef:
            name: {{ $api.existingSecret }}
      env:
        # 让 /api/version 返回镜像 tag，金丝雀时能分清请求落到哪个版本
        - name: MALL_VERSION
          value: {{ $api.image.tag | quote }}
        {{- with $api.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with $api.readinessProbe }}
      readinessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $api.livenessProbe }}
      livenessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if $api.preStopSleepSeconds }}
      lifecycle:
        preStop:
          sleep:
            seconds: {{ $api.preStopSleepSeconds }}
      {{- end }}
      {{- with $api.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $api.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  {{- with $api.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $api.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $api.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
