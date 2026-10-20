defmodule TSpecWeb.ContentController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.Content
  alias TSpecWeb.{ContentJSON, Schemas}

  plug OpenApiSpex.Plug.CastAndValidate, render_error: TSpecWeb.CastErrorRenderer
  action_fallback TSpecWeb.FallbackController

  tags ["content"]

  @id_param [id: [in: :path, type: :string, description: "Content id", required: true]]

  operation :create_video,
    summary: "Start a short-video upload",
    security: [%{"bearer" => []}],
    request_body: {"Caption", "application/json", Schemas.VideoUploadRequest},
    responses: [
      created: {"Upload slot", "application/json", Schemas.VideoUpload},
      unprocessable_entity: {"Invalid", "application/json", Schemas.Error}
    ]

  def create_video(conn, _params) do
    attrs = compact(conn.body_params)

    with {:ok, {item, upload}} <- Content.create_video_upload(conn.assigns.current_scope, attrs) do
      conn
      |> put_status(:created)
      |> json(%{
        content: ContentJSON.item(item),
        upload: Map.take(upload, [:url, :method, :form_field])
      })
    end
  end

  operation :create_post,
    summary: "Create a text post",
    security: [%{"bearer" => []}],
    request_body: {"Post", "application/json", Schemas.TextPostRequest},
    responses: [
      created: {"Post", "application/json", Schemas.ContentItem},
      unprocessable_entity: {"Invalid", "application/json", Schemas.Error}
    ]

  def create_post(conn, _params) do
    with {:ok, item} <-
           Content.create_text_post(conn.assigns.current_scope, compact(conn.body_params)) do
      conn |> put_status(:created) |> json(ContentJSON.item(item))
    end
  end

  operation :show,
    summary: "Get a content item",
    parameters: @id_param,
    responses: [
      ok: {"Item", "application/json", Schemas.ContentItem},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]

  def show(conn, %{id: id}) do
    with {:ok, item} <- Content.get_item(conn.assigns.current_scope, id) do
      json(conn, ContentJSON.item(item))
    end
  end

  operation :update,
    summary: "Edit a caption",
    parameters: @id_param,
    security: [%{"bearer" => []}],
    request_body: {"Caption", "application/json", Schemas.CaptionUpdate},
    responses: [
      ok: {"Item", "application/json", Schemas.ContentItem},
      forbidden: {"Not yours", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]

  def update(conn, %{id: id}) do
    attrs = %{caption: conn.body_params.caption}

    with {:ok, item} <- Content.update_caption(conn.assigns.current_scope, id, attrs) do
      json(conn, ContentJSON.item(item))
    end
  end

  operation :delete,
    summary: "Remove a content item",
    parameters: @id_param,
    security: [%{"bearer" => []}],
    responses: [
      no_content: "Removed",
      forbidden: {"Not yours", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]

  def delete(conn, %{id: id}) do
    with :ok <- Content.remove_item(conn.assigns.current_scope, id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp compact(struct) do
    for {k, v} <- Map.from_struct(struct), v != nil, into: %{}, do: {k, v}
  end
end
