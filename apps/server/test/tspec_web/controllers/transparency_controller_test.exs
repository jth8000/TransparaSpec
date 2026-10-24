defmodule TSpecWeb.TransparencyControllerTest do
  use TSpecWeb.ConnCase, async: true

  import OpenApiSpex.TestAssertions
  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.{Accounts, Events, Transparency}
  alias TSpec.Feed.{Interests, Ranker, Ranking}

  defp spec, do: TSpecWeb.ApiSpec.spec()

  setup do
    me = onboarded_user_fixture()
    %{me: me, scope: Accounts.scope_for_user(me), conn: json_conn() |> api_auth(me)}
  end

  defp watch!(scope, item) do
    v = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, _} =
      Events.record(scope, [
        %{content_id: item.id, view_id: v, type: "view_start", occurred_at: now},
        %{content_id: item.id, view_id: v, type: "complete", value: 2.0, occurred_at: now}
      ])

    {:ok, _} = Interests.apply_dirty_views(scope.user.id)
  end

  # Ranks and serves everything eligible under the user's current settings.
  defp serve!(scope) do
    settings = Transparency.get_settings(scope)

    {:ok, served} =
      Ranking.serve(scope, Ranking.rank(scope.user.id, settings), %{
        feed_session_id: Ecto.UUID.generate(),
        rev: 0,
        start_position: 0,
        settings: settings
      })

    served
  end

  describe "GET /api/impressions/:id" do
    test "returns the stored trace, and the settings as they were when served",
         %{conn: conn, scope: scope} do
      creator = onboarded_user_fixture()
      watch!(scope, ready_video_fixture(creator, topics: ["cooking"]))
      _ = text_post_fixture(onboarded_user_fixture(), topics: ["cooking"])

      {:ok, %{version: 1}} =
        Transparency.update_settings(scope, %{topics: %{"cooking" => %{multiplier: 1.5}}})

      [{scored, id} | _] = serve!(scope)

      # The user changes their settings again after the item was served.
      {:ok, %{version: 2}} =
        Transparency.update_settings(scope, %{topics: %{"cooking" => %{multiplier: 0.0}}})

      body = conn |> get(~p"/api/impressions/#{id}") |> json_response(200)
      assert_schema(body, "Explanation", spec())

      assert body["settings_version"] == 1
      assert body["settings"]["version"] == 1
      assert [%{"slug" => "cooking", "multiplier" => 1.5}] = body["settings"]["topics"]

      # Exactly what ranked it: same contributions, and they sum to the score.
      assert body["final_score"] === scored.final_score

      assert Ranker.sum(Enum.map(body["contributions"], &%{contribution: &1["contribution"]})) ===
               body["final_score"]

      assert length(body["contributions"]) == length(scored.contributions)
      assert body["topic_names"]["cooking"] == "Cooking"

      assert %{
               "feature" => "topic_preference",
               "user_multiplier" => 1.5,
               "label_sources" => ["creator"]
             } =
               Enum.find(body["contributions"], &(&1["feature"] == "topic_preference"))
    end

    test "is private, and unknown ids are 404", %{scope: scope} do
      _ = text_post_fixture(onboarded_user_fixture())
      [{_, id} | _] = serve!(scope)
      other = json_conn() |> api_auth(onboarded_user_fixture())

      assert other |> get(~p"/api/impressions/#{id}") |> json_response(404)
      assert other |> get(~p"/api/impressions/#{Ecto.UUID.generate()}") |> json_response(404)
    end
  end

  describe "algorithm settings" do
    test "read, change, reject invalid, reset", %{conn: conn} do
      body = conn |> get(~p"/api/algorithm/settings") |> json_response(200)
      assert_schema(body, "AlgorithmSettings", spec())
      assert %{"version" => 0, "topics" => [], "hard_off_threshold" => 0.5} = body
      assert "trending" in body["available_sources"]

      body =
        conn
        |> put(~p"/api/algorithm/settings", %{
          topics: %{"fitness-and-exercise" => %{hard_off: true}, "cooking" => %{multiplier: 1.5}},
          sources: %{"trending" => 0.5}
        })
        |> json_response(200)

      assert body["version"] == 1

      assert body["topics"] == [
               %{"slug" => "cooking", "multiplier" => 1.5, "hard_off" => false},
               %{"slug" => "fitness-and-exercise", "multiplier" => 1.0, "hard_off" => true}
             ]

      assert body["sources"] == [%{"source" => "trending", "multiplier" => 0.5}]

      # Out-of-range values fail schema validation; unknown slugs fail in the context.
      assert conn
             |> put(~p"/api/algorithm/settings", %{sources: %{"trending" => 5}})
             |> json_response(422)

      assert %{"error" => "invalid_settings"} =
               conn
               |> put(~p"/api/algorithm/settings", %{topics: %{"nope" => %{hard_off: true}}})
               |> json_response(422)

      assert %{"version" => 2, "topics" => [], "sources" => []} =
               conn |> post(~p"/api/algorithm/settings/reset") |> json_response(200)
    end
  end

  describe "interests" do
    test "lists what was learned, shows the evidence, and can forget it",
         %{conn: conn, scope: scope} do
      creator = onboarded_user_fixture()
      watched = ready_video_fixture(creator, topics: ["fitness-and-exercise"])
      watch!(scope, watched)

      body = conn |> get(~p"/api/me/interests") |> json_response(200)
      assert_schema(body, "Interests", spec())

      assert %{
               "name" => "Fitness and Exercise",
               "parent" => "healthy-living",
               "evidence_count" => 1,
               "score" => score
             } =
               Enum.find(body["topics"], &(&1["slug"] == "fitness-and-exercise"))

      # Decayed to "now", a few milliseconds after it was learned.
      assert_in_delta score, 1.0, 1.0e-6

      assert %{"handle" => handle} = hd(body["creators"])
      assert handle == creator.handle

      evidence =
        conn
        |> get(~p"/api/me/interests/topics/fitness-and-exercise/evidence")
        |> json_response(200)

      assert_schema(evidence, "InterestEvidence", spec())
      assert [%{"completed" => true, "delta" => 1.0, "item" => %{"id" => id}}] = evidence["views"]
      assert id == watched.id

      # The parent was credited at half weight by the same view.
      assert [%{"delta" => 0.5}] =
               conn
               |> get(~p"/api/me/interests/topics/healthy-living/evidence")
               |> json_response(200)
               |> Map.get("views")

      assert conn |> delete(~p"/api/me/interests/topics/fitness-and-exercise") |> response(204)
      body = conn |> get(~p"/api/me/interests") |> json_response(200)
      refute Enum.any?(body["topics"], &(&1["slug"] == "fitness-and-exercise"))

      assert conn |> delete(~p"/api/me/interests/creators/#{creator.id}") |> response(204)
      assert conn |> get(~p"/api/me/interests") |> json_response(200) |> Map.get("creators") == []

      assert conn |> get(~p"/api/me/interests/topics/nope/evidence") |> json_response(404)
    end
  end

  describe "dashboard" do
    test "aggregates only what was actually shown", %{conn: conn, scope: scope} do
      creator = onboarded_user_fixture()
      watch!(scope, ready_video_fixture(creator, topics: ["fitness-and-exercise"]))
      _ = text_post_fixture(onboarded_user_fixture(), topics: ["fitness-and-exercise"])
      _ = text_post_fixture(onboarded_user_fixture(), topics: ["cooking"])

      served = serve!(scope)
      assert length(served) >= 2

      # Only the first one is shown (view_start with its impression).
      [{scored, imp} | _] = served

      {:ok, _} =
        Events.record(scope, [
          %{
            content_id: scored.content_id,
            type: "view_start",
            occurred_at: DateTime.utc_now(),
            impression_id: imp
          }
        ])

      body = conn |> get(~p"/api/algorithm/dashboard?days=7") |> json_response(200)
      assert_schema(body, "Dashboard", spec())
      assert body["shown"] == 1
      assert [%{"topics" => [%{"count" => 1}]}] = body["topic_mix"]

      features = Enum.map(body["top_drivers"], & &1["feature"])
      assert "source_prior" in features
      assert Enum.sum(Enum.map(body["top_drivers"], & &1["total"])) > 0

      assert conn |> get(~p"/api/algorithm/dashboard?days=30") |> json_response(200)
      assert conn |> get(~p"/api/algorithm/dashboard?days=5") |> json_response(422)
    end
  end
end
