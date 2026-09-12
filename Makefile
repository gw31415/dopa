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

.PHONY: build app test check

build: .build/release/dopa .build/release/dopa-daemon

app: .build/Dopa.app/Contents/MacOS/dopa-ui

test: .build/.make/test

check: test build

.build/release/dopa: $(BUILD_CONFIG) $(CLI_SOURCES)
	mise exec -- swift build $(STRICT_RELEASE_FLAGS) --product dopa
	touch $@

.build/release/dopa-daemon: $(BUILD_CONFIG) $(DAEMON_SOURCES)
	mise exec -- swift build $(STRICT_RELEASE_FLAGS) --product dopa-daemon
	touch $@

.build/Dopa.app/Contents/MacOS/dopa-ui: \
	$(BUILD_CONFIG) \
	scripts/build-app.sh \
	$(APP_RESOURCES) \
	$(ALL_SOURCES)
	./scripts/build-app.sh

.build/.make/test: \
	$(BUILD_CONFIG) \
	prototypes/ui/schedule.mjs \
	prototypes/ui/schedule.test.mjs \
	$(ALL_SOURCES) \
	$(TEST_SOURCES)
	mise exec -- swift test
	mise exec -- node --test prototypes/ui/schedule.test.mjs
	mkdir -p $(@D)
	touch $@
