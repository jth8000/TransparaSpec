# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tspec, :scopes,
  user: [
    default: true,
    module: TSpec.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: TSpec.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :tspec,
  namespace: TSpec,
  ecto_repos: [TSpec.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :tspec, TSpecWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TSpecWeb.ErrorHTML, json: TSpecWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TSpec.PubSub,
  live_view: [signing_salt: "1wJyN9XA"]

# Background jobs (Postgres-backed). Queues per architecture.md; more are
# added as phases land (ml, affinity, ranking, ledger, safety).
config :tspec, Oban,
  engine: Oban.Engines.Basic,
  repo: TSpec.Repo,
  queues: [default: 10, media: 4, affinity: 5, ranking: 2, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"15 3 * * *", TSpec.Events.PartitionWorker},
       {"*/10 * * * *", TSpec.Feed.AffinitySweepWorker},
       {"*/5 * * * *", TSpec.Feed.TrendingWorker},
       {"45 3 * * *", TSpec.Events.ImpressionPruneWorker},
       {"20 * * * *", TSpec.Content.ExpireUploadsWorker}
     ]}
  ]

# Origins allowed to call the JSON API from a browser (the Expo web client).
config :tspec, :cors_origins, []

# Video providers (ADR 0005). New uploads go to `:video_provider`; existing
# rows keep the provider they were created with.
config :tspec, :video_providers, %{
  "local" => TSpec.Video.LocalProvider,
  "cloudflare" => TSpec.Video.CloudflareStream
}

config :tspec, :video_provider, "local"

# Where magic links in sign-in emails point (the Expo web client).
config :tspec, :client_url, "http://localhost:8081"

# HMAC key for stored sign-in codes. Dev/test only; prod reads
# LOGIN_CODE_SECRET in runtime.exs.
config :tspec, :login_code_secret, "dev-only-login-code-secret-not-for-production"

# Per-client-address limits, `{requests, window_ms}` per node
# (`TSpecWeb.RateLimit`). Dev and test raise them for repeated E2E runs.
config :tspec, :rate_limits,
  auth_request: {10, :timer.minutes(10)},
  auth_verify: {30, :timer.minutes(10)}

# Header holding the client's address when behind a proxy (`TSpecWeb.ClientIP`).
# Unset: use the socket's peer address. Production sets it in runtime.exs.
config :tspec, :client_ip_header, nil

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tspec, TSpec.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tspec: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  tspec: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Keep credentials out of logs. Phoenix filters any parameter whose name
# contains one of these, including the socket's `?token=` on connect.
config :phoenix, :filter_parameters, ["password", "token", "code", "secret"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
