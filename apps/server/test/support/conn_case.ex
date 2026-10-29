defmodule TSpecWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use TSpecWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint TSpecWeb.Endpoint

      use TSpecWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import TSpecWeb.ConnCase
    end
  end

  setup tags do
    TSpec.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "A test conn that sends JSON, as the API clients do (the spec validates content-type)."
  def json_conn do
    Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  @doc "Authenticates `conn` against the JSON API as `user` (bearer token)."
  def api_auth(conn, user) do
    token = TSpec.AccountsFixtures.api_token_fixture(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end
end
