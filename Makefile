SHELL := /bin/bash
TOOLCHAIN := source scripts/toolchain.sh &&
FORMAT_PATHS := Sources Tests Benchmarks Package.swift

.PHONY: all build release test lint fmt fmt-check clean help

all: build test ## Build everything and run the tests

build: ## Debug build of every target
	$(TOOLCHAIN) swift build

release: ## Release build of rfb-view and rfb-bench
	$(TOOLCHAIN) swift build -c release --product rfb-view
	$(TOOLCHAIN) swift build -c release --product rfb-bench

test: ## Build and run the swift-testing suite
	scripts/test.sh

lint: fmt-check ## Check formatting and build with warnings as errors
	$(TOOLCHAIN) swift build -Xswiftc -warnings-as-errors

fmt: ## Format code with swift format
	$(TOOLCHAIN) swift format -i -r --configuration .swift-format $(FORMAT_PATHS)

fmt-check: ## Check formatting (fails on any finding)
	$(TOOLCHAIN) swift format lint --strict -r --configuration .swift-format $(FORMAT_PATHS)

clean: ## Remove build artifacts
	rm -rf .build

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
