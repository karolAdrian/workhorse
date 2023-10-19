PREFIX=/usr/local

FIPS_MODE ?= 0
PKG := gitlab.com/gitlab-org/gitlab/workhorse
BUILD_DIR ?= $(CURDIR)
TARGET_DIR ?= $(BUILD_DIR)/_build
VERSION_STRING := $(shell git describe)
ifeq ($(strip $(VERSION_STRING)),)
VERSION_STRING := v$(shell cat VERSION)
endif
DATE_FMT = +%Y%m%d.%H%M%S
ifdef SOURCE_DATE_EPOCH
	BUILD_TIME := $(shell date -u -d "@$(SOURCE_DATE_EPOCH)" "$(DATE_FMT)" 2>/dev/null || date -u -r "$(SOURCE_DATE_EPOCH)" "$(DATE_FMT)" 2>/dev/null || date -u "$(DATE_FMT)")
else
	BUILD_TIME := $(shell date -u "$(DATE_FMT)")
endif
GO_BUILD_GENERIC_LDFLAGS := -X main.Version=$(VERSION_STRING) -X main.BuildTime=$(BUILD_TIME)
GITALY  := tmp/tests/gitaly/_build/bin/gitaly
GITALY_PID_FILE := gitaly.pid
EXE_ALL := gitlab-resize-image gitlab-zip-cat gitlab-zip-metadata gitlab-workhorse
INSTALL := install
BUILD_TAGS := tracer_static tracer_static_jaeger continuous_profiler_stackdriver

ifeq (${FIPS_MODE}, 1)
    # boringcrypto tag is added automatically by golang-fips compiler
    BUILD_TAGS += fips
    # If the golang-fips compiler is built with CGO_ENABLED=0, this needs to be
    # explicitly switched on.
    export CGO_ENABLED=1
    # Go 1.19+ now requires GOEXPERIMENT=boringcrypto for FIPS compilation.
    # See https://github.com/golang/go/issues/51940 for more details.
    ifeq ($(shell GOEXPERIMENT=boringcrypto go version > /dev/null 2>&1; echo $$?), 0)
      export GOEXPERIMENT=boringcrypto
    endif
endif

export GOBIN := $(TARGET_DIR)/bin
export PATH := $(GOBIN):$(PATH)
export GOPROXY ?= https://proxy.golang.org
export GO111MODULE=on

define message
	@echo "### $(1)"
endef

# To compute a unique and deterministic value for GNU build-id, we build the Go binary a second time.
# From the first build, we extract its unique and deterministic Go build-id, and use that to derive
# a comparably unique and deterministic GNU build-id to inject into the final binary.
# If we cannot extract a Go build-id, we punt and fallback to using a random 32-byte hex string.
# This fallback is unique but non-deterministic.  Uniqueness is critical, because the GNU build-id
# can be used as a cache key in a build cache.  Without the fallback, we risk cache key collisions.
## Skip generation of the GNU build ID if set to speed up builds.
WITHOUT_BUILD_ID ?=

.NOTPARALLEL:

.PHONY:	all
all:	clean-build $(EXE_ALL)

.PHONY: gitlab-resize-image gitlab-zip-cat gitlab-zip-metadata
gitlab-resize-image gitlab-zip-cat gitlab-zip-metadata:
	$(call message,Building $@)
	go build -ldflags "$(GO_BUILD_GENERIC_LDFLAGS)" -tags "$(BUILD_TAGS)" -o $(BUILD_DIR)/$@ $(PKG)/cmd/$@
ifndef WITHOUT_BUILD_ID
	go build -ldflags "$(GO_BUILD_GENERIC_LDFLAGS) -B 0x$$(_support/make-gnu-build-id.sh $(BUILD_DIR)/$@)" -tags "$(BUILD_TAGS)" -o $(BUILD_DIR)/$@ $(PKG)/cmd/$@
endif

.PHONY: gitlab-workhorse
gitlab-workhorse:
	$(call message,Building $@)
	go build -ldflags "$(GO_BUILD_GENERIC_LDFLAGS)" -tags "$(BUILD_TAGS)" -o $(BUILD_DIR)/$@ $(PKG)
ifndef WITHOUT_BUILD_ID
	go build -ldflags "$(GO_BUILD_GENERIC_LDFLAGS) -B 0x$$(_support/make-gnu-build-id.sh $(BUILD_DIR)/$@)" -tags "$(BUILD_TAGS)" -o $(BUILD_DIR)/$@ $(PKG)
endif

.PHONY:	install
install: $(EXE_ALL)
	$(call message,$@)
	mkdir -p $(DESTDIR)$(PREFIX)/bin/
	cd $(BUILD_DIR) && $(INSTALL) $(EXE_ALL) $(DESTDIR)$(PREFIX)/bin/

.PHONY:	test
test: prepare-tests
	$(call message,$@)
	@if [ -z "$${GITALY_ADDRESS+x}" ] ; then \
		echo "To run gitaly integration tests set GITALY_ADDRESS=tcp://127.0.0.1:8075" ; \
	else \
		$(MAKE) run-gitaly ; \
	fi
	go test ${TEST_OPTIONS} -tags "$(BUILD_TAGS)" ./...
	@status="$$?" ;\
	if [ -f "$(GITALY_PID_FILE)" ] ; then \
		echo "Clean up Gitaly server for workhorse integration test" ;\
		kill -9 $$(cat $(GITALY_PID_FILE)) ;\
		rm $(GITALY_PID_FILE) ;\
	else \
		echo "Gitaly integration test not running" ;\
	fi ;\
	exit "$$status"
	@echo SUCCESS

.PHONY: test-race
test-race: TEST_OPTIONS = -race
test-race: test

.PHONY: test-coverage
test-coverage: TEST_OPTIONS = -cover -coverprofile=cover.out
test-coverage: test
	$(call message, "Calculating the coverage")
	[ -f cover.out ] && go tool cover -html cover.out -o coverage.html
	[ -f cover.out ] && go tool cover -func cover.out

.PHONY:	clean
clean: clean-workhorse clean-build
	$(call message,$@)
	rm -rf testdata/data testdata/scratch cover.out coverage.html

.PHONY:	clean-workhorse
clean-workhorse:
	$(call message,$@)
	rm -f $(EXE_ALL)

.PHONY:	clean-build
clean-build:
	$(call message,$@)
	rm -rf $(TARGET_DIR)

.PHONY:	prepare-tests
prepare-tests: testdata/scratch $(EXE_ALL)

.PHONY: run-gitaly
run-gitaly: $(GITALY_PID_FILE)

$(GITALY_PID_FILE): gitaly.toml
	$(call message, "Starting gitaly")
	cd ..; GITALY_TESTING_NO_GIT_HOOKS=1 GITALY_PID_FILE=workhorse/$(GITALY_PID_FILE) scripts/gitaly-test-spawn workhorse/gitaly.toml

gitaly.toml: ../tmp/tests/gitaly/config.toml
	sed -e 's/^socket_path.*$$/listen_addr = "0.0.0.0:8075"/;s/^\[auth\]$$//;s/^token.*$$//;s/^internal_socket_dir.*$$//' \
		$< > $@

../tmp/tests/gitaly/config.toml:
	$(call message, "Building a complete test environment")
	cd .. ; ./scripts/setup-test-env

testdata/scratch:
	mkdir -p testdata/scratch

.PHONY: verify
verify: lint vet detect-context detect-assert detect-external-tests check-formatting staticcheck deps-check

.PHONY: lint
lint:
	$(call message,Verify: $@)
	go install golang.org/x/lint/golint
	@_support/lint.sh ./...

.PHONY: vet
vet:
	$(call message,Verify: $@)
	@go vet ./...

.PHONY: detect-context
detect-context:
	$(call message,Verify: $@)
	_support/detect-context.sh

.PHONY: detect-assert
detect-assert:
	$(call message,Verify: $@)
	_support/detect-assert.sh

.PHONY: detect-external-tests
detect-external-tests:
	$(call message,Verify: $@)
	_support/detect-external-tests.sh

.PHONY: check-formatting
check-formatting: install-goimports
	$(call message,Verify: $@)
	@_support/fmt.sh check

# Megacheck will tailor some responses given a minimum Go version, so pass that through the CLI
# Additionally, megacheck will not return failure exit codes unless explicitly told to via the
# `-simple.exit-non-zero` `-unused.exit-non-zero` and `-staticcheck.exit-non-zero` flags
.PHONY: staticcheck
staticcheck:
	$(call message,Verify: $@)
	go install honnef.co/go/tools/cmd/staticcheck
	@ $(GOBIN)/staticcheck ./...

# In addition to fixing imports, goimports also formats your code in the same style as gofmt
# so it can be used as a replacement.
.PHONY: fmt
fmt: install-goimports
	$(call message,$@)
	@_support/fmt.sh

.PHONY:	goimports
install-goimports:
	$(call message,$@)
	go install golang.org/x/tools/cmd/goimports

.PHONY: deps-check
deps-check:
	go mod tidy
	@if git diff --quiet --exit-code -- go.mod go.sum; then \
		echo "go.mod and go.sum are ok"; \
	else \
		echo ""; \
		echo "go.mod and go.sum are modified, please commit them";\
		exit 1; \
	fi;
