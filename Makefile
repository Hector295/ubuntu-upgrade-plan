CLUSTER ?= lab
TOOLS   := tools/bin
OUT     := out
KUSTOMIZE_BUILD := $(TOOLS)/kustomize build --load-restrictor LoadRestrictionsNone

SHELL_SCRIPTS := scripts/*.sh scripts/lib/*.sh tools/install.sh tests/stubs/* tests/k8s-stubs/* docs/ejemplos/*.sh $(wildcard manifests/overlays/*/post-upgrade-hook.sh)

.PHONY: help tools lint test render validate check clean

help:
	@echo "make tools                 descarga las herramientas fijadas en tools/bin"
	@echo "make lint                  shellcheck de todos los scripts"
	@echo "make test                  tests bats (lógica de upgrade.sh y manifiestos)"
	@echo "make render CLUSTER=lab    genera $(OUT)/<cluster>.yaml desde manifests/overlays/<cluster>"
	@echo "make validate CLUSTER=lab  render + validación contra el CRD del cluster"
	@echo "make check                 lint + test + validate"

tools:
	@sh tools/install.sh

lint: tools
	$(TOOLS)/shellcheck -s sh $(SHELL_SCRIPTS)
	$(TOOLS)/shellcheck -s bash tests/bats/*.bash

test: tools
	$(TOOLS)/bats tests/bats

render: tools
	@test -d manifests/overlays/$(CLUSTER) || { echo "No existe manifests/overlays/$(CLUSTER)"; exit 1; }
	@mkdir -p $(OUT)
	$(KUSTOMIZE_BUILD) manifests/overlays/$(CLUSTER) > $(OUT)/$(CLUSTER).yaml
	@echo "Generado $(OUT)/$(CLUSTER).yaml"

validate: render
	sh scripts/validate-manifests.sh $(OUT)/$(CLUSTER).yaml manifests/schemas/$(CLUSTER)

check: lint test validate

clean:
	rm -rf $(OUT)
