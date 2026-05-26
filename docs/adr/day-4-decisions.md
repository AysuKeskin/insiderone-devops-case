# Day 4 Architecture Decisions

Observability decisions, in the same lightweight ADR style as the earlier files.
Numbering continues from `day-3-decisions.md`.

## ADR 010 - kube-prometheus-stack, run locally for the demo

Status: Accepted

Metrics, dashboards, and alerting use the `kube-prometheus-stack` Helm chart
(Prometheus + Grafana + Alertmanager + the Prometheus Operator) instead of
hand-rolled manifests. One install gives a working stack, and the Operator's
`ServiceMonitor`/`PrometheusRule` CRDs let the app declare its own scrape config
and alerts from inside its own chart.

I run the stack on **local minikube**, not the EC2 host. The `t3.medium` (4 GB)
already carries the app and minikube's control plane, and the full monitoring
stack wants roughly 2 GB more than fits comfortably there. The deliverable is a
dashboard screenshot and one alert, both of which the local stack covers, and
this lines up with the dev=local / prod=cloud split (ADR 009).

The cost: no always-on hosted Grafana. A production setup would give monitoring
its own node or ship metrics to a hosted backend (Grafana Cloud, Amazon Managed
Prometheus).

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

The public endpoint runs over HTTPS on a custom domain.
cert-manager requests a Let's Encrypt certificate and ingress-nginx terminates
TLS at the origin. Cloudflare sits in front in **Full (strict)** mode, so traffic
is encrypted on both legs: browser to Cloudflare, and Cloudflare to origin.

I used the **DNS-01** ACME challenge (via a Cloudflare API token) rather than
HTTP-01. HTTP-01 has to reach the origin on port 80, which fights with the
Cloudflare proxy being on; DNS-01 only needs a TXT record, so it works no matter
how the proxy is set up. TLS is opt-in in the chart (`ingress.tls.*`): off in the
base values, on in `values-prod.yaml`. The chart still emits a catch-all rule next
to the host rule, so the raw Elastic IP keeps answering over plain HTTP.

The cost: a Cloudflare API token now lives as a cluster secret (scoped to
Zone:DNS:Edit), and cert-manager is one more moving part on the EC2 node.
