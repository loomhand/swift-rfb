SHELL := /bin/bash
TOOLCHAIN := source scripts/toolchain.sh &&

.PHONY: all build release test clean help

all: build test ## Build everything and run the tests

build: ## Debug build of every target
	$(TOOLCHAIN) swift build

release: ## Release build of rfb-view and rfb-bench
	$(TOOLCHAIN) swift build -c release --product rfb-view
	$(TOOLCHAIN) swift build -c release --product rfb-bench

test: ## Build and run the swift-testing suite
	scripts/test.sh

clean: ## Remove build artifacts
	rm -rf .build

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
