APP        := kube-pulse
GH_OWNER   ?= aysukeskin
IMAGE      := ghcr.io/$(GH_OWNER)/$(APP)
VERSION    := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT     := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILT_AT   := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
TAG        ?= $(COMMIT)

CHART      := helm/kube-pulse
RELEASE    := kube-pulse

MONITORING_NS := monitoring

.PHONY: help run test docker-test build docker-build docker-run scan compose-up compose-down clean lint helm-lint helm-template deploy-dev deploy-prod rollback rollout-status rollout-dev rollout-prod helm-history helm-uninstall minikube-load monitoring-install monitoring-grafana monitoring-prometheus load-gen tls-install

help: ## list targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

run: ## run locally with `go run`
	go run ./cmd/server

test: ## run unit tests (needs Go locally)
	go test ./... -race -cover

docker-test: ## run unit tests inside a golang container (no local Go needed)
	docker run --rm -v "$(CURDIR)":/src -w /src golang:1.25 go test ./... -race -cover

lint: ## run go vet
	go vet ./...

build: ## build local binary
	go build -trimpath -ldflags="-s -w" -o bin/server ./cmd/server

docker-build: ## build container image
	docker build \
	  --build-arg VERSION=$(VERSION) \
	  --build-arg COMMIT=$(COMMIT) \
	  --build-arg BUILT_AT=$(BUILT_AT) \
	  -t $(IMAGE):$(TAG) \
	  -t $(IMAGE):latest \
	  .

docker-run: ## run container locally on :8080
	docker run --rm -p 8080:8080 --read-only --cap-drop=ALL $(IMAGE):$(TAG)

scan: ## trivy scan, fail on CRITICAL/HIGH
	trivy image --severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed $(IMAGE):$(TAG)

compose-up: ## docker compose up --build
	docker compose up --build

compose-down: ## docker compose down
	docker compose down

clean: ## remove build artifacts
	rm -rf bin/

helm-lint: ## lint the Helm chart against dev values
	helm lint $(CHART) -f $(CHART)/values-dev.yaml

helm-template: ## render templates locally for inspection
	helm template $(RELEASE) $(CHART) -f $(CHART)/values-dev.yaml

minikube-load: ## load the locally-built image into minikube
	minikube image load $(IMAGE):$(TAG)

deploy-dev: ## deploy to minikube with values-dev.yaml
	helm upgrade --install $(RELEASE) $(CHART) \
	  -f $(CHART)/values-dev.yaml \
	  --set image.tag=$(TAG) \
	  --set image.pullPolicy=Never

deploy-prod: ## deploy to minikube with values-prod.yaml
	helm upgrade --install $(RELEASE) $(CHART) \
	  -f $(CHART)/values-prod.yaml \
	  --set image.tag=$(TAG) \
	  --set image.pullPolicy=Never

rollout-status: ## wait for the current Deployment rollout to finish (2 min cap)
	kubectl rollout status deployment/$(RELEASE) --timeout=2m

rollout-dev: deploy-dev rollout-status ## deploy dev and wait for pods to be Ready

rollout-prod: deploy-prod rollout-status ## deploy prod and wait for pods to be Ready

rollback: ## roll back to the previous revision and wait for it to be Ready
	helm rollback $(RELEASE)
	kubectl rollout status deployment/$(RELEASE) --timeout=2m

helm-history: ## show release history
	helm history $(RELEASE)

helm-uninstall: ## remove the release
	helm uninstall $(RELEASE)

monitoring-install: ## install kube-prometheus-stack into the monitoring namespace
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
	  -n $(MONITORING_NS) --create-namespace

monitoring-grafana: ## port-forward Grafana to localhost:3000 (user admin; see README for pw)
	kubectl -n $(MONITORING_NS) port-forward svc/monitoring-grafana 3000:80

monitoring-prometheus: ## port-forward Prometheus to localhost:9090
	kubectl -n $(MONITORING_NS) port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090

load-gen: ## hammer /ping to populate RPS/latency panels (Ctrl-C to stop)
	while true; do curl -s localhost:8080/ping >/dev/null; done

tls-install: ## install cert-manager (for ingress TLS via Let's Encrypt DNS-01)
	helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
	  --namespace cert-manager --create-namespace \
	  --version v1.20.2 --set crds.enabled=true
