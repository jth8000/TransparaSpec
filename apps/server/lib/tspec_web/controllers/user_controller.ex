defmodule TSpecWeb.UserController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.{Accounts, Social}
  alias TSpec.Accounts.Scope
  alias TSpecWeb.{Schemas, UserJSON}

  plug OpenApiSpex.Plug.CastAndValidate, render_error: TSpecWeb.CastErrorRenderer
  action_fallback TSpecWeb.FallbackController

  tags ["users"]

  @handle_param [handle: [in: :path, type: :string, description: "User handle", required: true]]

  operation :show,
    summary: "Public profile",
    parameters: @handle_param,
    responses: [
      ok: {"Profile", "application/json", Schemas.PublicProfile},
      not_found: {"No such user", "application/json", Schemas.Error}
    ]

  def show(conn, %{handle: handle}) do
    with {:ok, user} <- fetch_user(handle) do
      scope = conn.assigns.current_scope
      followed_by_me = match?(%Scope{}, scope) and Social.following?(scope, user)
      json(conn, UserJSON.public_profile(user, Social.counts(user), followed_by_me))
    end
  end

  operation :follow,
    summary: "Follow a user",
    parameters: @handle_param,
    security: [%{"bearer" => []}],
    responses: [
      no_content: "Following",
      not_found: {"No such user", "application/json", Schemas.Error},
      unprocessable_entity: {"Can't follow yourself", "application/json", Schemas.Error}
    ]

  def follow(conn, %{handle: handle}) do
    with {:ok, user} <- fetch_user(handle),
         :ok <- Social.follow(conn.assigns.current_scope, user) do
      send_resp(conn, :no_content, "")
    end
  end

  operation :unfollow,
    summary: "Unfollow a user",
    parameters: @handle_param,
    security: [%{"bearer" => []}],
    responses: [
      no_content: "Not following",
      not_found: {"No such user", "application/json", Schemas.Error}
    ]

  def unfollow(conn, %{handle: handle}) do
    with {:ok, user} <- fetch_user(handle),
         :ok <- Social.unfollow(conn.assigns.current_scope, user) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch_user(handle) do
    case Accounts.get_user_by_handle(handle) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end
end
