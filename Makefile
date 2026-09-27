# GLB Print Prep: common tasks. Run `make help`.
.DEFAULT_GOAL := help
.PHONY: help setup lint format test test-engine test-app build app app-dev clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## Install engine dependencies
	cd engine && npm ci

lint: ## Biome (engine) + swift-format and SwiftLint (app)
	cd engine && npx biome ci .
	cd app && swift format lint --strict --recursive Sources Tests Package.swift
	cd app && swiftlint --strict

format: ## Auto-format engine and app sources
	cd engine && npx biome check --write .
	cd app && swift format --in-place --recursive Sources Tests Package.swift
	cd app && swiftlint --fix

test: test-engine test-app ## Run all tests

test-engine: ## Engine tests (node:test)
	cd engine && npm test

test-app: ## App core tests (Swift Testing)
	cd app && swift test

build: ## Debug build of the app package
	cd app && swift build

app: ## Build dist/GLB Print Prep.app with bundled Node.js
	app/scripts/build-app.sh

app-dev: ## Build the app using the system Node.js (faster)
	BUNDLE_NODE=0 app/scripts/build-app.sh

clean: ## Remove build outputs (keeps the Node.js download cache)
	rm -rf dist app/.build
