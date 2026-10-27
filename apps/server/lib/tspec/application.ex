defmodule TSpec.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TSpecWeb.Telemetry,
      TSpec.Repo,
      {DNSCluster, query: Application.get_env(:tspec, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TSpec.PubSub},
      {Oban, Application.fetch_env!(:tspec, Oban)},
      {TSpec.RateLimit, clean_period: :timer.minutes(10)},
      # Per-feed-session ranking caches (ADR 0011).
      {DynamicSupervisor, name: TSpec.Feed.SessionSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: TSpec.TaskSupervisor},
      # Start to serve requests, typically the last entry
      TSpecWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TSpec.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TSpecWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
