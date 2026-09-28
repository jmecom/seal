.PHONY: build test test-validators smoke acp-smoke protocol-smoke check

build:
	go build -o bin/seal-bridge ./cmd/seal-bridge

test:
	go test ./...
	nvim --headless -u NONE -l tests/client_spec.lua
	nvim --headless -u NONE -l tests/acp_spec.lua
	nvim --headless -u NONE -l tests/alto_spec.lua
	nvim --headless -u NONE -l tests/buffer_model_spec.lua
	nvim --headless -u NONE -l tests/work_items_spec.lua
	nvim --headless -u NONE -l tests/seal_scheduler_spec.lua
	nvim --headless -u NONE -l tests/seal_spec.lua

test-validators:
	SEAL_REQUIRE_OPTIONAL_PARSERS=1 nvim --headless -u NONE -l tests/seal_spec.lua

smoke: build
	nvim --headless -u NONE -l tests/seal_smoke.lua

acp-smoke:
	SEAL_BACKEND=acp nvim --headless -u NONE -l tests/seal_smoke.lua
	SEAL_BACKEND=acp nvim --headless -u NONE -l tests/app_server_smoke.lua

protocol-smoke: build
	nvim --headless -u NONE -l tests/app_server_smoke.lua

check: build
	test -z "$$(gofmt -l cmd)"
	go vet ./...
	go test -race ./...
	$(MAKE) test
