defmodule TSpec.ProdConfigTest do
  # Reads the production config files the way a release does, so settings
  # that only exist in prod are checked somewhere. It sets OS environment
  # variables, so it can't run alongside other tests.
  use ExUnit.Case, async: false

  @config_dir Path.expand("../../config", __DIR__)

  @required_env %{
    "DATABASE_URL" => "ecto://user:pass@db.example.com/tspec",
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "LOGIN_CODE_SECRET" => "test-login-code-secret",
    "CLIENT_URL" => "https://app.example.com",
    "DNS_CLUSTER_QUERY" => "tspec.internal"
  }

  defp with_env(env, fun) do
    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(env, fn {key, value} -> set_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {key, value} -> set_env(key, value) end)
    end
  end

  defp set_env(key, nil), do: System.delete_env(key)
  defp set_env(key, value), do: System.put_env(key, value)

  defp runtime_config(extra_env) do
    with_env(Map.merge(@required_env, extra_env), fn ->
      Config.Reader.read!(Path.join(@config_dir, "runtime.exs"), env: :prod)
    end)
  end

  test "production never registers or serves the local video provider" do
    config = Config.Reader.read!(Path.join(@config_dir, "config.exs"), env: :prod)

    assert Map.keys(config[:tspec][:video_providers]) == ["cloudflare"]
    refute config[:tspec][:local_video]
  end

  test "production compiles out the dev routes (LiveDashboard, the mailbox)" do
    config = Config.Reader.read!(Path.join(@config_dir, "config.exs"), env: :prod)

    refute config[:tspec][:dev_routes]
  end

  test "the database connection uses verified TLS unless DATABASE_SSL=false" do
    assert runtime_config(%{"DATABASE_SSL" => nil})[:tspec][TSpec.Repo][:ssl] == true
    assert runtime_config(%{"DATABASE_SSL" => "false"})[:tspec][TSpec.Repo][:ssl] == false
  end
end
