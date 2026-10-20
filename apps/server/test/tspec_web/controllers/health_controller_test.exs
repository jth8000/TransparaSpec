defmodule TSpecWeb.HealthControllerTest do
  use TSpecWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions

  test "GET /api/health returns ok and matches the spec", %{conn: conn} do
    body = conn |> get(~p"/api/health") |> json_response(200)

    assert body == %{"status" => "ok"}
    assert_schema(body, "Health", TSpecWeb.ApiSpec.spec())
  end

  test "GET /api/openapi serves the spec", %{conn: conn} do
    spec = conn |> get(~p"/api/openapi") |> json_response(200)

    assert spec["info"]["title"] == "T-Spec API"
    assert Map.has_key?(spec["paths"], "/api/health")
  end
end
