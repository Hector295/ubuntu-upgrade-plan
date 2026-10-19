CLUSTER ?= lab
TOOLS   := tools/bin
OUT     := out
DIST    := dist
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
IMAGE   ?= ghcr.io/hector295/os-upgrade
KUSTOMIZE_BUILD := $(TOOLS)/kustomize build --load-restrictor LoadRestrictionsNone

SHELL_SCRIPTS := bin/os-upgrade scripts/*.sh scripts/lib/*.sh lab/*.sh tools/*.sh tests/stubs/* tests/k8s-stubs/* tests/lab-stubs/* docs/examples/*.sh $(wildcard manifests/overlays/*/post-upgrade-hook.sh)

.PHONY: help tools lint test render validate check dist image clean

help:
	@echo "make tools                 download the pinned tools into tools/bin"
	@echo "make lint                  shellcheck of every script"
	@echo "make test                  bats tests (node script, operator scripts, manifests, lab)"
	@echo "make render CLUSTER=lab    generate $(OUT)/<cluster>.yaml from manifests/overlays/<cluster>"
	@echo "make validate CLUSTER=lab  render + validation against the cluster CRD"
	@echo "make check                 lint + test + validate"
	@echo "make dist                  release tarball in $(DIST)/ (VERSION=$(VERSION))"
	@echo "make image                 dist + container image $(IMAGE):$(VERSION)"

tools:
	@sh tools/install.sh

lint: tools
	$(TOOLS)/shellcheck -s sh $(SHELL_SCRIPTS)
	$(TOOLS)/shellcheck -s bash tests/bats/*.bash

test: tools
	$(TOOLS)/bats tests/bats

render: tools
	@test -d manifests/overlays/$(CLUSTER) || { echo "manifests/overlays/$(CLUSTER) does not exist"; exit 1; }
	@mkdir -p $(OUT)
	$(KUSTOMIZE_BUILD) manifests/overlays/$(CLUSTER) > $(OUT)/$(CLUSTER).yaml
	@echo "Generated $(OUT)/$(CLUSTER).yaml"

validate: render
	sh scripts/validate-manifests.sh $(OUT)/$(CLUSTER).yaml manifests/schemas/$(CLUSTER)

check: lint test validate

dist: tools
	sh tools/dist.sh $(VERSION) $(DIST)

image: dist
	docker build --build-arg VERSION=$(VERSION) -t $(IMAGE):$(VERSION) .

clean:
	rm -rf $(OUT) $(DIST)
