STRICT_RELEASE_FLAGS := --configuration release \
	-Xswiftc -warnings-as-errors \
	-Xcc -Wall -Xcc -Wextra -Xcc -Werror

BUILD_CONFIG := Package.swift Makefile mise.toml mise.lock
CLI_SOURCES := $(wildcard \
	Sources/DopaCLI/*.swift \
	Sources/DopaClient/*.swift \
	Sources/DopaProtocol/*.swift)
DAEMON_SOURCES := $(wildcard \
	Sources/CDopa/*.c \
	Sources/CDopa/include/*.h \
	Sources/DopaAuthorization/*.swift \
	Sources/DopaClient/*.swift \
	Sources/DopaCore/*.swift \
	Sources/DopaDaemonCLI/*.swift \
	Sources/DopaManagement/*.swift \
	Sources/DopaProtocol/*.swift)
ALL_SOURCES := $(wildcard \
	Sources/*/*.swift \
	Sources/*/*.c \
	Sources/*/include/*.h)
TEST_SOURCES := $(wildcard Tests/*/*.swift)
APP_RESOURCES := \
	Resources/Dopa-Info.plist \
	Resources/Dopa.icon/icon.json \
	$(wildcard Resources/Dopa.icon/Assets/*.svg)

.PHONY: build app test check FORCE

FORCE:

build: .build/.make/dopa .build/.make/dopa-daemon

app: .build/.make/app

test: .build/.make/test

check: test build

.build/.make/dopa: $(BUILD_CONFIG) $(CLI_SOURCES) FORCE
	@if test -x .build/release/dopa \
		&& .build/release/dopa --help >/dev/null 2>&1; then artifact_ok=1; \
	else artifact_ok=0; fi; \
	if test "$$artifact_ok" -eq 1 && test -z "$(filter-out FORCE,$?)"; then \
		:; \
	else \
		set -e; \
		rm -f $@; \
		if test "$$artifact_ok" -eq 0; then rm -f .build/release/dopa; fi; \
		mise exec -- swift build $(STRICT_RELEASE_FLAGS) --product dopa; \
		test -x .build/release/dopa; \
		.build/release/dopa --help >/dev/null; \
		mkdir -p $(@D); \
		touch $@; \
	fi

.build/.make/dopa-daemon: $(BUILD_CONFIG) $(DAEMON_SOURCES) FORCE
	@if test -x .build/release/dopa-daemon \
		&& .build/release/dopa-daemon --help >/dev/null 2>&1; then artifact_ok=1; \
	else artifact_ok=0; fi; \
	if test "$$artifact_ok" -eq 1 && test -z "$(filter-out FORCE,$?)"; then \
		:; \
	else \
		set -e; \
		rm -f $@; \
		if test "$$artifact_ok" -eq 0; then rm -f .build/release/dopa-daemon; fi; \
		mise exec -- swift build $(STRICT_RELEASE_FLAGS) --product dopa-daemon; \
		test -x .build/release/dopa-daemon; \
		.build/release/dopa-daemon --help >/dev/null; \
		mkdir -p $(@D); \
		touch $@; \
	fi

.build/.make/app: \
	$(BUILD_CONFIG) \
	scripts/build-app.sh \
	$(APP_RESOURCES) \
	$(ALL_SOURCES) \
	FORCE
	@if test -x .build/Dopa.app/Contents/MacOS/dopa-ui \
		&& test -x .build/Dopa.app/Contents/Helpers/dopa \
		&& test -x .build/Dopa.app/Contents/Helpers/dopa-daemon \
		&& codesign --verify --deep --strict .build/Dopa.app >/dev/null 2>&1 \
		&& .build/Dopa.app/Contents/Helpers/dopa --help >/dev/null 2>&1 \
		&& .build/Dopa.app/Contents/Helpers/dopa-daemon --help >/dev/null 2>&1 \
		&& test -z "$(filter-out FORCE,$?)"; then \
		:; \
	else \
		set -e; \
		rm -f $@; \
		./scripts/build-app.sh; \
		mkdir -p $(@D); \
		touch $@; \
	fi

.build/.make/test: \
	$(BUILD_CONFIG) \
	prototypes/ui/schedule.mjs \
	prototypes/ui/schedule.test.mjs \
	$(ALL_SOURCES) \
	$(TEST_SOURCES)
	rm -f $@
	mise exec -- swift test
	mise exec -- node --test prototypes/ui/schedule.test.mjs
	mkdir -p $(@D)
	touch $@
