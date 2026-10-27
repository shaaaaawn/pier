# Pier — build/test/run front door.
.DEFAULT_GOAL := help
.PHONY: help build test run fixture anchor logs cmux docker apple activity menubar viewport statusitem selfevent applog applog-follow fmt lint check clean

help: ## show this list
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: ## assemble + ad-hoc sign dist/Pier.app
	./scripts/build-app.sh

test: ## run the unit suite
	swift test

run: build ## rebuild, then (re)launch the menu bar app
	@pkill -x Pier 2>/dev/null || true
	@sleep 1
	open dist/Pier.app

fixture: ## render fixture PNGs (list, expanded, activity, preview states)
	swift build
	.build/debug/Pier --render-fixture /tmp/pier.png
	.build/debug/Pier --render-fixture-expanded /tmp/pier-expanded.png
	.build/debug/Pier --render-fixture-activity /tmp/pier-activity.png
	.build/debug/Pier --render-fixture-preview /tmp/pier-preview.png
	.build/debug/Pier --render-fixture-idle /tmp/pier-idle.png
	.build/debug/Pier --render-fixture-down /tmp/pier-down.png
	.build/debug/Pier --render-fixture-events /tmp/pier-events.png
	.build/debug/Pier --render-fixture-narrow /tmp/pier-narrow.png

logs: ## tail a real container to verify streaming: make logs C=data_postgres
	@if [ -z "$(C)" ]; then echo "usage: make logs C=<container>"; exit 1; fi
	swift build
	.build/debug/Pier --tail-docker "$(C)"

apple: ## report Apple container engine state + reclaimable space
	swift build
	.build/debug/Pier --print-apple

docker: ## report Docker engine state + reclaimable space
	swift build
	.build/debug/Pier --print-docker

cmux: ## report whether cmux workspace grouping can work
	swift build
	.build/debug/Pier --print-cmux

menubar: ## report which displays currently draw or reserve menu bar space
	swift build
	.build/debug/Pier --print-menubar

anchor: ## report where the panel lands vs its menu bar icon
	swift build
	.build/debug/Pier --probe-anchor

activity: ## print the live Docker/Containers/MCP snapshot
	swift build
	.build/debug/Pier --print-activity

idlecpu: ## measure what the panel costs while CLOSED (both arms)
	swift build
	.build/debug/Pier --probe-idle-cpu 10

viewport: ## check the CSS viewport a preview gets: make viewport URL=http://…
	@if [ -z "$(URL)" ]; then echo "usage: make viewport URL=http://127.0.0.1:3000"; exit 1; fi
	swift build
	.build/debug/Pier --probe-viewport "$(URL)" /tmp/pier-viewport.png

statusitem: ## report the persisted defaults that can hide/misplace the menu bar icon
	swift build
	.build/debug/Pier --probe-statusitem

selfevent: ## verify Pier's own kills read as "you" (spawns + kills a throwaway listener)
	swift build
	.build/debug/Pier --probe-self-event

applog: ## tail Pier's own log: ~/Library/Logs/Pier/pier.log (N=lines, default 50)
	@swift build 2>/dev/null
	@.build/debug/Pier --tail-log $(or $(N),50)

applog-follow: ## follow Pier's own log live (Ctrl-C to stop)
	@tail -f "$$HOME/Library/Logs/Pier/pier.log"

fixture-baseline: ## capture fixture renders before a refactor
	./scripts/fixture-check.sh baseline

fixture-check: ## re-render and fail on any pixel difference vs the baseline
	./scripts/fixture-check.sh check

fmt: ## format sources with Xcode's bundled swift-format (no install needed)
	xcrun swift-format format --in-place --parallel Sources/Pier/*.swift Tests/PierTests/*.swift

lint: ## fail on style violations — run before committing
	xcrun swift-format lint --strict --parallel Sources/Pier/*.swift Tests/PierTests/*.swift

check: lint test ## the gate: style + the full suite

clean: ## remove SPM build products
	rm -rf .build dist/Pier.app
