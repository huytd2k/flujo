.PHONY: dev check runner-build

dev:
	@command -v gleam >/dev/null || { echo "gleam is required"; exit 1; }
	@command -v npm >/dev/null || { echo "npm is required"; exit 1; }
	@set -eu; \
		gleam run & backend_pid=$$!; \
		trap 'kill $$backend_pid 2>/dev/null || true' INT TERM EXIT; \
		npm --prefix frontend run dev -- --host 0.0.0.0

check:
	gleam test
	docker build --target frontend -t flujo-frontend-check .

runner-build:
	docker build -f docker/comfy/Dockerfile -t flujo-comfy:cu130 .
