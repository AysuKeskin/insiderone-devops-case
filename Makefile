APP        := insiderone-devops-case
GH_OWNER   ?= aysukeskin
IMAGE      := ghcr.io/$(GH_OWNER)/$(APP)
VERSION    := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT     := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILT_AT   := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
TAG        ?= $(COMMIT)

CHART      := helm/insiderone-devops-case
RELEASE    := insiderone-devops-case

.PHONY: help run test docker-test build docker-build docker-run scan compose-up compose-down clean lint helm-lint helm-template deploy-dev deploy-prod rollback rollout-status rollout-dev rollout-prod helm-history helm-uninstall minikube-load

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

rollback: ## rollback the release to the previous revision
	helm rollback $(RELEASE)

helm-history: ## show release history
	helm history $(RELEASE)

helm-uninstall: ## remove the release
	helm uninstall $(RELEASE)
