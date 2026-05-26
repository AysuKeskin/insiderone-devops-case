# Day 4 Architecture Decisions

Observability decisions, in the same lightweight ADR style as the earlier files.
Numbering continues from `day-3-decisions.md`.

## ADR 010 - kube-prometheus-stack, run locally for the demo

Status: Accepted

Metrics, dashboards, and alerting use the `kube-prometheus-stack` Helm chart
(Prometheus + Grafana + Alertmanager + the Prometheus Operator) rather than
hand-rolled deployments, because one install gives a working, well-supported
stack and the Operator's `ServiceMonitor`/`PrometheusRule` CRDs let the app
declare its own scrape config and alerts from inside its chart. We run the stack
on **local minikube**, not the EC2 host: the `t3.medium` (4 GB) already runs the
app plus minikube's control plane, and the full monitoring stack wants ~2 GB more
than is comfortable there. The case deliverable is a dashboard screenshot and an
alert, both of which the local stack satisfies, and this matches the
dev=local / prod=cloud split (ADR 009). Tradeoff: there is no always-on hosted
Grafana; a production setup would run monitoring on its own node or ship metrics
to a hosted backend (Grafana Cloud, Amazon Managed Prometheus).

## ADR 011 - Metrics use the matched route, not the raw path, as a label

Status: Accepted

`http_requests_total` and `http_request_duration_seconds` are labelled with the
matched ServeMux route (`r.Pattern`, e.g. `GET /ping`) instead of the raw request
URL. Labelling by raw path is the classic Prometheus cardinality trap: any
unique URL (or a path-scanning bot) would create an unbounded number of time
series and eventually OOM Prometheus. Using the route keeps the label set bounded
to the handful of registered routes, with unmatched requests collapsed to
`"unmatched"`. The `/metrics` endpoint itself is excluded from the counter so that
Prometheus's own scrapes don't inflate the RPS panels.

## ADR 012 - HTTPS via cert-manager + Let's Encrypt (DNS-01), behind Cloudflare

Status: Accepted

The public endpoint is served over HTTPS on a custom domain (Going further #6).
The origin certificate is issued by cert-manager from Let's Encrypt and the
ingress (`ingress-nginx`) terminates TLS; Cloudflare sits in front in
**Full (strict)** mode, so the connection is encrypted browser→Cloudflare and
Cloudflare→origin. We chose the **DNS-01** ACME challenge (Cloudflare API token)
over HTTP-01 because DNS-01 works regardless of Cloudflare's proxy state — an
HTTP-01 challenge has to reach the origin on port 80, which is awkward when the
orange-cloud proxy and Full-strict are both on. TLS is **opt-in** in the chart
(`ingress.tls.*`, off by default in the base values, on in `values-prod.yaml`).
The chart still emits a catch-all rule alongside the host rule, so the raw IP
keeps answering over HTTP. Tradeoff: a Cloudflare API token now lives as a cluster
secret (scoped to Zone:DNS:Edit), and cert-manager is one more component on the
EC2 node.
