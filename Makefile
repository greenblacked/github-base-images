# Local build & smoke-test helper -- reproduces what a PR run does, minus the
# registry writes and the Trivy scans. CI stays the source of truth: it also
# builds both architectures on native runners and enforces the vulnerability and
# secret gates. This is just a fast local loop while editing a Dockerfile.ci or
# a test.sh.
#
#   make list                        # show the images this repo builds
#   make check IMAGE=ci-rust185      # build one image from upstream, then smoke-test it
#   make build IMAGE=ci-ruby34       # build only, tagged ci-ruby34:test
#   make test  IMAGE=ci-ruby34       # smoke-test an already-built ci-ruby34:test
#   make check-all                   # build + test every image
#
# Builds default to the host architecture and the upstream base -- no ghcr.io
# authentication needed, exactly like a PR run (which never touches the mirror).
# Override TAG for the local tag, or PLATFORM to cross-build under emulation
# (e.g. PLATFORM=linux/amd64 on Apple Silicon).

# Every directory that ships a Dockerfile.ci is an image.
IMAGES   := $(patsubst %/Dockerfile.ci,%,$(wildcard */Dockerfile.ci))
TAG      ?= test
PLATFORM ?=
PLATFORM_ARG := $(if $(PLATFORM),--platform $(PLATFORM),)

.DEFAULT_GOAL := help

.PHONY: help list guard-image build test check build-all test-all check-all

help:
	@echo "Images: $(IMAGES)"
	@echo
	@echo "Targets:"
	@echo "  make list                    list the images this repo builds"
	@echo "  make build IMAGE=<name>      build <name> locally as <name>:$(TAG) (from upstream)"
	@echo "  make test  IMAGE=<name>      run <name>/test.sh against <name>:$(TAG)"
	@echo "  make check IMAGE=<name>      build then test <name>"
	@echo "  make {build,test,check}-all  same across every image"
	@echo
	@echo "Vars: IMAGE, TAG (default 'test'), PLATFORM (e.g. linux/amd64)"

list:
	@printf '%s\n' $(IMAGES)

# IMAGE must name a real image directory before build/test run.
guard-image:
	@test -n "$(IMAGE)" || { echo "error: set IMAGE=<name>, e.g. IMAGE=ci-rust185" >&2; exit 2; }
	@test -f "$(IMAGE)/Dockerfile.ci" || { echo "error: no such image '$(IMAGE)' (try 'make list')" >&2; exit 2; }

build: guard-image
	docker build $(PLATFORM_ARG) -f "$(IMAGE)/Dockerfile.ci" -t "$(IMAGE):$(TAG)" "$(IMAGE)"

test: guard-image
	./$(IMAGE)/test.sh "$(IMAGE):$(TAG)"

check: build test

build-all:
	@for img in $(IMAGES); do $(MAKE) --no-print-directory build IMAGE=$$img || exit 1; done

test-all:
	@for img in $(IMAGES); do $(MAKE) --no-print-directory test IMAGE=$$img || exit 1; done

check-all:
	@for img in $(IMAGES); do $(MAKE) --no-print-directory check IMAGE=$$img || exit 1; done
