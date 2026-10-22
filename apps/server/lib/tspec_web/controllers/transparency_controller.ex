defmodule TSpecWeb.TransparencyController do
  @moduledoc "Explanations, algorithm controls, learned interests and the dashboard."
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.Transparency
  alias TSpecWeb.{Schemas, TransparencyJSON}

  plug OpenApiSpex.Plug.CastAndValidate, render_error: TSpecWeb.CastErrorRenderer
  action_fallback TSpecWeb.FallbackController

  tags ["transparency"]
  security [%{"bearer" => []}]

  @not_found {"Not found", "application/json", Schemas.Error}

  operation :explain,
    summary: "Why am I seeing this? (the stored trace of one served item)",
    parameters: [id: [in: :path, type: :string, required: true, description: "Impression id"]],
    responses: [
      ok: {"Explanation", "application/json", Schemas.Explanation},
      not_found: @not_found
    ]

  def explain(conn, %{id: id}) do
    with {:ok, explanation} <- Transparency.explain(conn.assigns.current_scope, id) do
      json(conn, TransparencyJSON.explanation(explanation))
    end
  end

  operation :settings,
    summary: "Your algorithm controls",
    responses: [ok: {"Settings", "application/json", Schemas.AlgorithmSettings}]

  def settings(conn, _params) do
    json(conn, TransparencyJSON.settings(Transparency.get_settings(conn.assigns.current_scope)))
  end

  operation :update_settings,
    summary: "Change algorithm controls (your open feeds re-rank live)",
    request_body: {"Changes", "application/json", Schemas.SettingsChange},
    responses: [
      ok: {"Settings", "application/json", Schemas.AlgorithmSettings},
      unprocessable_entity: {"Invalid", "application/json", Schemas.Error}
    ]

  def update_settings(conn, _params) do
    with {:ok, settings} <-
           Transparency.update_settings(conn.assigns.current_scope, changes(conn.body_params)) do
      json(conn, TransparencyJSON.settings(settings))
    end
  end

  operation :reset_settings,
    summary: "Reset topic and source controls to the defaults",
    responses: [ok: {"Settings", "application/json", Schemas.AlgorithmSettings}]

  def reset_settings(conn, _params) do
    with {:ok, settings} <- Transparency.reset_settings(conn.assigns.current_scope) do
      json(conn, TransparencyJSON.settings(settings))
    end
  end

  operation :interests,
    summary: "What the algorithm has learned about you",
    responses: [ok: {"Interests", "application/json", Schemas.Interests}]

  def interests(conn, _params) do
    json(conn, TransparencyJSON.interests(Transparency.interests(conn.assigns.current_scope)))
  end

  operation :interest_evidence,
    summary: "The views a topic interest was learned from",
    parameters: [slug: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Evidence", "application/json", Schemas.InterestEvidence},
      not_found: @not_found
    ]

  def interest_evidence(conn, %{slug: slug}) do
    with {:ok, views} <- Transparency.interest_evidence(conn.assigns.current_scope, slug) do
      json(conn, TransparencyJSON.evidence(views))
    end
  end

  operation :forget_interest,
    summary: "Forget a learned topic interest",
    parameters: [slug: [in: :path, type: :string, required: true]],
    responses: [no_content: "Forgotten", not_found: @not_found]

  def forget_interest(conn, %{slug: slug}) do
    with :ok <- Transparency.forget_interest(conn.assigns.current_scope, slug) do
      send_resp(conn, :no_content, "")
    end
  end

  operation :forget_creator_interest,
    summary: "Forget a learned creator interest (following is unaffected)",
    parameters: [id: [in: :path, type: :string, required: true, description: "Creator user id"]],
    responses: [no_content: "Forgotten", not_found: @not_found]

  def forget_creator_interest(conn, %{id: id}) do
    with :ok <- Transparency.forget_creator_interest(conn.assigns.current_scope, id) do
      send_resp(conn, :no_content, "")
    end
  end

  operation :dashboard,
    summary: "Algorithm Dashboard: topic mix and top drivers of what you were shown",
    parameters: [days: [in: :query, type: %OpenApiSpex.Schema{type: :integer, enum: [7, 30]}]],
    responses: [ok: {"Dashboard", "application/json", Schemas.Dashboard}]

  def dashboard(conn, params) do
    json(conn, Transparency.dashboard(conn.assigns.current_scope, Map.get(params, :days, 7)))
  end

  # The cast body (atom keys for known properties; slugs and sources stay
  # strings) to the change map Transparency.update_settings/2 takes.
  defp changes(body) do
    body = if is_struct(body), do: Map.from_struct(body), else: body

    %{}
    |> put_present(:topics, topics(Map.get(body, :topics)))
    |> put_present(:sources, Map.get(body, :sources))
    |> put_present(:non_personalized, Map.get(body, :non_personalized))
  end

  defp topics(nil), do: nil

  defp topics(topics) do
    Map.new(topics, fn {slug, change} ->
      change = if is_struct(change), do: Map.from_struct(change), else: change

      {to_string(slug),
       for({k, v} <- change, k in [:multiplier, :hard_off], v != nil, into: %{}, do: {k, v})}
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
