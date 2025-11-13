# =====================[ Release / Versioning ]=====================
# Required per-repo var:
REPO ?= peetvandesande/mariadb-backup

PLAT_BUILD             ?= linux/amd64
PLAT_PUSH              ?= linux/amd64,linux/arm64
BUILDER                ?= multiarch

# --- Build context + Dockerfile location -------------------------------------
VARIANT        ?= alpine
BUILD_CONTEXT  ?= .
DOCKERFILE     ?= $(VARIANT)/Dockerfile

# Optional: also tag with the variant name
TAG_VARIANT    := -$(VARIANT)

# Optional metadata (edit per project)
IMAGE_TITLE            ?= file-backup
IMAGE_DESCRIPTION      ?= "Simple backup/restore utility (Alpine)"
IMAGE_SOURCE_URL       ?= $(shell git remote get-url origin | sed 's/^git@/https:\/\//; s/\.git$$//; s/:/\//')
IMAGE_REPO_URL         ?= https://hub.docker.com/r/$(REPO)
IMAGE_AUTHORS          ?= "Peet van de Sande <peet@peetvandesande.com>"

# Derived metadata
GIT_SHA                := $(shell git rev-parse --short=8 HEAD)
GIT_CREATED            := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_BRANCH             := $(shell git rev-parse --abbrev-ref HEAD)

# ---------- helpers ----------
LATEST_TAG             := $(shell git tag --list 'v*' | sort -V | tail -1)
LATEST_VERSION_STRIP   := $(shell echo "$(LATEST_TAG)" | sed -E 's/^v//')
# If no tags yet, start at 0.0.0
LATEST_SAFE            := $(if $(LATEST_VERSION_STRIP),$(LATEST_VERSION_STRIP),0.0.0)

# bump functions (pure make/shell)
define bump_patch
echo "$(LATEST_SAFE)" | awk -F. '{printf "%d.%d.%d\n", $$1, $$2, $$3+1}'
endef
define bump_minor
echo "$(LATEST_SAFE)" | awk -F. '{printf "%d.%d.%d\n", $$1, $$2+1, 0}'
endef
define bump_major
echo "$(LATEST_SAFE)" | awk -F. '{printf "%d.%d.%d\n", $$1+1, 0, 0}'
endef

.PHONY: print-version next-patch next-minor next-major \
        release release-patch release-minor release-major \
        check-clean check-version tag-version build-multi push-tag

print-version:
	@echo "Repo:           $(REPO)"
	@echo "Branch:         $(GIT_BRANCH)"
	@echo "Latest tag:     $(if $(LATEST_TAG),$(LATEST_TAG),<none>)"
	@echo "Latest version: $(LATEST_SAFE)"
	@echo "Next (patch):   v$$( $(bump_patch) )"
	@echo "Next (minor):   v$$( $(bump_minor) )"
	@echo "Next (major):   v$$( $(bump_major) )"
	@echo "Git SHA:        $(GIT_SHA)"
	@echo "Created:        $(GIT_CREATED)"
	@echo "Platforms:      build=$(PLAT_BUILD) push=$(PLAT_PUSH)"

next-patch:
	@$(bump_patch)

next-minor:
	@$(bump_minor)

next-major:
	@$(bump_major)

# ===== Release entry points =====
# Usage:
#   make release VERSION=1.2.3
#   make release-patch
#   make release-minor
#   make release-major

release: check-clean check-version confirm-release tag-version build-multi push-tag
	@echo "✅ Release v$(VERSION) completed for $(REPO)"

release-patch:
	@$(MAKE) release VERSION=$$($(bump_patch))

release-minor:
	@$(MAKE) release VERSION=$$($(bump_minor))

release-major:
	@$(MAKE) release VERSION=$$($(bump_major))

check-clean:
	@if ! git diff-index --quiet HEAD --; then \
		echo "ERROR: Working tree not clean. Commit or stash changes before releasing."; \
		exit 1; \
	fi

check-version:
	@if [ -z "$(VERSION)" ]; then \
		echo "ERROR: VERSION must be specified (example: make release VERSION=1.2.3)"; \
		exit 1; \
	fi
	@if ! echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		echo "ERROR: VERSION must follow semver (e.g., 1.2.3)"; \
		exit 1; \
	fi

confirm-release:
	@echo "Releasing v$(VERSION) for $(REPO)"
	@printf "Proceed? (y/N) "; read ans; [ "$$ans" = "y" ]

tag-version:
	git tag -a v$(VERSION) -m "Release v$(VERSION)"
	git push --tags

# Build & push multi-arch with proper OCI labels
build-multi:
	docker buildx build \
		--builder $(BUILDER) \
		--platform $(PLAT_PUSH) \
		--label org.opencontainers.image.title="$(IMAGE_TITLE)" \
		--label org.opencontainers.image.description=$(IMAGE_DESCRIPTION) \
		--label org.opencontainers.image.url=$(IMAGE_REPO_URL) \
		--label org.opencontainers.image.source=$(IMAGE_SOURCE_URL) \
		--label org.opencontainers.image.revision="$(GIT_SHA)" \
		--label org.opencontainers.image.version="v$(VERSION)" \
		--label org.opencontainers.image.created="$(GIT_CREATED)" \
		--label org.opencontainers.image.authors=$(IMAGE_AUTHORS) \
		-t $(REPO):v$(VERSION) \
		-t $(REPO):latest \
		-t $(REPO):v$(VERSION)$(TAG_VARIANT) \
		-f $(DOCKERFILE) \
		--push \
		$(BUILD_CONTEXT)

push-tag:
	@echo "Git tag pushed: v$(VERSION)"

# --- Dev builds (no version tag bump, no git tagging) ------------------------

.PHONY: build-dev push-dev

# Build local image for testing (no push)
build-dev:
	docker buildx build \
		--builder $(BUILDER) \
		--platform $(PLAT_BUILD) \
		--load \
		-t $(REPO):dev \
		-t $(REPO):dev$(TAG_VARIANT) \
		-f $(DOCKERFILE) \
		$(BUILD_CONTEXT)

# Build and push multi-arch dev image
push-dev:
	docker buildx build \
		--builder $(BUILDER) \
		--platform $(PLAT_PUSH) \
		--label org.opencontainers.image.revision="$(GIT_SHA)" \
		--label org.opencontainers.image.created="$(GIT_CREATED)" \
		-t $(REPO):dev \
		-t $(REPO):dev$(TAG_VARIANT) \
		-f $(DOCKERFILE) \
		--push \
		$(BUILD_CONTEXT)
	@echo "✅ Pushed: $(REPO):dev"

