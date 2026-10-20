import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :tspec, TSpec.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5440")),
  database: "tspec_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tspec, TSpecWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "AqU6ceoGPIJ/BfLZTC4m3mOZwtrNVLMbuwxo+7orar7C8BznDRMRjzywxdQCus4x",
  server: false

# In test we don't send emails
config :tspec, TSpec.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Jobs are executed explicitly in tests (Oban.Testing / perform_job).
config :tspec, Oban, testing: :manual

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :tspec, :local_video, true

config :tspec, TSpec.Video.LocalProvider,
  base_url: "http://localhost:4002",
  media_root: Path.expand("../tmp/test_media", __DIR__),
  secret: "test-only-local-video-secret",
  webhook: :inline

# Cloudflare Stream is exercised against Req.Test stubs, never the network.
config :tspec, TSpec.Video.CloudflareStream,
  account_id: "test-account",
  api_token: "test-token",
  webhook_secret: "test-webhook-secret",
  customer_subdomain: "customer-test.cloudflarestream.com",
  req_options: [plug: {Req.Test, TSpec.Video.CloudflareStream}, retry: false]
