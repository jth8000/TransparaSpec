# Common tasks. Tool versions: Erlang/Elixir via mise (.tool-versions),
# Node via nvm (.nvmrc) — run `nvm use` first in a new shell.

SERVER := apps/server

.PHONY: setup db db-stop dev client android web test test-server test-client api-gen api-check security e2e

setup: db
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

test: test-server test-client api-check

test-server: db
	cd $(SERVER) && mix format --check-formatted && mix compile --warnings-as-errors && mix test --warnings-as-errors

test-client:
	npm run typecheck -w apps/client
	npm run lint -w apps/client
	npm test -w apps/client

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

e2e:
	npm test -w e2e
