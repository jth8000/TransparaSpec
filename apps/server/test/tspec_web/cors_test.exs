defmodule TSpecWeb.CORSTest do
  use TSpecWeb.ConnCase, async: false

  defp preflight(origin) do
    build_conn()
    |> put_req_header("origin", origin)
    |> put_req_header("access-control-request-method", "POST")
    |> options("/api/auth/request")
  end

  defp allowed(conn), do: get_resp_header(conn, "access-control-allow-origin")

  test "dev/test: any localhost port may call the API (Expo web moves off a busy 8081)" do
    for origin <- ~w(http://localhost:8081 http://localhost:8082 http://127.0.0.1:19006) do
      assert allowed(preflight(origin)) == [origin]
    end
  end

  test "other origins get no CORS grant" do
    assert allowed(preflight("https://evil.example")) == []
    assert allowed(preflight("http://localhost.evil.example")) == []
  end

  test "configured origins are allowed, and localhost isn't when the dev rule is off" do
    on_exit(fn ->
      Application.put_env(:tspec, :cors_allow_localhost, true)
      Application.put_env(:tspec, :cors_origins, [])
    end)

    Application.put_env(:tspec, :cors_allow_localhost, false)
    Application.put_env(:tspec, :cors_origins, ["https://app.tspec.example"])

    assert allowed(preflight("https://app.tspec.example")) == ["https://app.tspec.example"]
    assert allowed(preflight("http://localhost:8082")) == []
  end
end
