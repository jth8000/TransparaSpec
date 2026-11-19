# Common tasks. Tool versions: Erlang/Elixir via mise (.tool-versions),
# Node via nvm (.nvmrc) — run `nvm use` first in a new shell. Python (the ML
# service) via uv, which reads services/ml/.python-version.

SERVER := apps/server
ML := services/ml
# The ML service runs in its own uv environment. An inherited PYTHONPATH (a
# ROS install sets one) would leak other packages and pytest plugins into it.
UV := env -u PYTHONPATH uv

.PHONY: setup db db-stop dev client android web test test-server test-client test-ml ml ml-setup api-gen api-check security expo-check expo-fix mutation-check mutation-patterns e2e

setup: db ml-setup
	cd $(SERVER) && mix setup
	npm install

db:
	docker compose up -d --wait db

db-stop:
	docker compose stop db

# Phoenix API on http://localhost:4000 (dev mailbox at /dev/mailbox).
dev: db
	cd $(SERVER) && iex -S mix phx.server

# Expo dev server. `android` builds/installs the dev app on the running
# emulator (first build takes a few minutes) and maps the emulator's
# localhost:4000 to this machine, so the app reaches the API at the same URL
# as the web build.
client:
	npm run start -w apps/client

android:
	adb reverse tcp:4000 tcp:4000
	cd apps/client && npx expo run:android

web:
	npm run web -w apps/client -- --port 8081

test: mutation-patterns test-server test-client test-ml api-check

# Every mutation check's pattern still matches its code (under a second).
mutation-patterns:
	python3 scripts/mutation_checks.py --check-patterns

test-server: db
	cd $(SERVER) && mix format --check-formatted && mix compile --warnings-as-errors && mix test --warnings-as-errors

test-client:
	npm run typecheck -w apps/client
	npm run lint -w apps/client
	npm test -w apps/client

ml-setup:
	cd $(ML) && $(UV) sync

# The ML service on http://localhost:8000, with fake models, fetching media
# from LocalProvider (`make dev`). One worker: the one-request-at-a-time lock
# lives in the process.
ml:
	cd $(ML) && TSPEC_ML_SECRET=dev-only-ml-secret-0123456789abcdef \
	  TSPEC_ML_ALLOWED_MEDIA_HOSTS=localhost:4000 TSPEC_ML_ALLOW_HTTP=true \
	  $(UV) run uvicorn tspec_ml.main:create_app --factory --host 127.0.0.1 --port 8000 --workers 1

test-ml:
	cd $(ML) && $(UV) run ruff check . && $(UV) run ruff format --check . && $(UV) run pytest -q

# Regenerate the OpenAPI spec and the typed TS client from the server.
api-gen:
	cd $(SERVER) && mix openapi.spec.json --spec TSpecWeb.ApiSpec --pretty=true ../../packages/api-schema/openapi.json
	npm run gen -w packages/api-schema

# Fails if the committed spec/client are out of date with the server.
api-check: api-gen
	git diff --exit-code -- packages/api-schema

# Dependency advisories and static security checks. Needs the network.
# A Sobelow finding that is a false positive gets a `# sobelow_skip` comment
# saying why; an npm advisory that can't reach production goes in
# scripts/npm-audit-allowlist.json with the reason.
security:
	cd $(SERVER) && mix hex.audit
	cd $(SERVER) && mix sobelow --skip --exit low --private --quiet
	node scripts/npm-audit.mjs
	cd $(ML) && $(UV) export --frozen --no-emit-project --format requirements-txt --quiet > .audit-requirements.txt \
	  && $(UV) run pip-audit --strict --disable-pip --require-hashes -r .audit-requirements.txt; \
	  status=$$?; rm -f .audit-requirements.txt; exit $$status

# Expo-managed packages (expo-*, react, react-native, ...) must match the
# versions Expo publishes for our SDK. Checked against Expo's versions API,
# so it needs the network and goes stale when Expo ships SDK patches;
# `expo-fix` moves them all together. Dependabot doesn't touch them.
expo-check:
	npm run expo-check -w apps/client

expo-fix:
	cd apps/client && npx expo install --fix

# Breaks each concurrency/security guard listed in docs/review/concurrency.md
# and checks its tests fail. Takes a few minutes; not part of `make test`
# (which runs only `mutation-patterns`).
mutation-check: db
	python3 scripts/mutation_checks.py

e2e:
	npm test -w e2e
