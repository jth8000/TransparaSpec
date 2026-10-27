defmodule Mix.Tasks.Tspec.SeedDemo do
  @shortdoc "Seeds demo creators and topic-labeled content (dev only)"
  @moduledoc """
  Creates demo creators and labeled short videos and text posts across a
  few topics, so For You has something to rank:

      mix tspec.seed_demo

  Videos go through the real LocalProvider pipeline (upload → ffmpeg HLS
  transcode → signed webhook → ready). Each topic gets its own background
  color, and the caption names the topic. Idempotent: does nothing if the
  demo creators already exist. Dev only (needs the local video provider and
  ffmpeg).
  """
  use Mix.Task

  import Ecto.Query

  alias TSpec.{Accounts, Content, Repo}
  alias TSpec.Accounts.User
  alias TSpec.Video.LocalProvider

  @requirements ["app.start"]

  # {topic slug, label, background color, captions}
  @topics [
    {"fitness-and-exercise", "Fitness", "0xd95926",
     ["Leg day burner", "5-minute core", "Mobility flow", "Sprint intervals"]},
    {"cooking", "Cooking", "0x199e70",
     ["Sheet-pan dinner", "Knife skills 101", "Perfect rice", "One-pot pasta"]},
    {"video-gaming", "Gaming", "0x3987e5",
     ["Speedrun tricks", "Boss fight fails", "Cozy game picks", "Retro unboxing"]},
    {"music", "Music", "0xd55181",
     ["Two-chord jam", "Drum fill of the day", "Synth patch", "Busking at noon"]},
    {"travel", "Travel", "0xc98500",
     ["Hidden beach", "Night market food", "Train window views", "Packing light"]},
    {"pets", "Pets", "0x9085e9", ["Cat vs. box", "New puppy", "Parrot says hi", "Zoomies"]}
  ]
  @creators_per_topic 2
  @videos_per_creator 2
  @posts_per_creator 1

  @impl Mix.Task
  def run(_args) do
    unless Application.get_env(:tspec, :local_video) && System.find_executable("ffmpeg") do
      Mix.raise("tspec.seed_demo needs the dev LocalProvider and ffmpeg")
    end

    if Repo.exists?(from u in User, where: like(u.handle, "demo_%")) do
      Mix.shell().info("Demo creators already exist; nothing to do.")
    else
      seed()
    end
  end

  defp seed do
    # Deliver provider webhooks in-process: `make dev` may not be running.
    env = Application.fetch_env!(:tspec, LocalProvider)
    Application.put_env(:tspec, LocalProvider, Keyword.put(env, :webhook, :inline))

    dir = Path.join(System.tmp_dir!(), "tspec-seed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    ids =
      for {{slug, label, color, captions}, t} <- Enum.with_index(@topics),
          c <- 1..@creators_per_topic do
        creator = creator!("demo_#{String.replace(slug, "-", "_")}_#{c}")
        scope = Accounts.scope_for_user(creator)
        clip = clip!(dir, color)

        videos =
          for v <- 1..@videos_per_creator do
            caption =
              Enum.at(captions, rem((c - 1) * @videos_per_creator + v - 1, length(captions)))

            {:ok, {item, upload}} =
              Content.create_video_upload(scope, %{
                caption: "#{caption} ##{label}",
                topics: [slug]
              })

            :ok = LocalProvider.store_upload(upload.asset_id, clip)
            item.id
          end

        for p <- 1..@posts_per_creator do
          {:ok, _} =
            Content.create_text_post(scope, %{
              body: "#{label} thought ##{p} from @#{creator.handle}",
              topics: [slug]
            })
        end

        Mix.shell().info("  #{label}: @#{creator.handle} (#{t + 1}/#{length(@topics)})")
        videos
      end
      |> List.flatten()

    Mix.shell().info("Transcoding #{length(ids)} videos…")
    wait_until_ready(ids, 180)
    File.rm_rf!(dir)

    Mix.shell().info(
      "Done: #{length(@topics) * @creators_per_topic} creators, #{length(ids)} videos."
    )
  end

  defp creator!(handle) do
    {:ok, user} = Accounts.register_user(%{email: "#{handle}@demo.tspec.test"})

    user =
      user |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second)) |> Repo.update!()

    {:ok, user} =
      Accounts.onboard_user(user, %{
        handle: handle,
        birthdate: ~D[1995-06-15],
        accept_consent_version: Accounts.current_consent_document().version
      })

    user
  end

  # A 3-second vertical clip: a solid topic color with a moving test pattern.
  defp clip!(dir, color) do
    path = Path.join(dir, "#{color}.mp4")

    unless File.exists?(path) do
      {_, 0} =
        System.cmd("ffmpeg", [
          "-y",
          "-v",
          "error",
          "-f",
          "lavfi",
          "-i",
          "color=c=#{color}:s=720x1280:d=3:r=24",
          "-f",
          "lavfi",
          "-i",
          "testsrc2=s=360x360:d=3:r=24",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=330:duration=3",
          "-filter_complex",
          "[0][1]overlay=x=180:y='460+200*sin(2*PI*t/3)'[v]",
          "-map",
          "[v]",
          "-map",
          "2",
          "-c:v",
          "libx264",
          "-pix_fmt",
          "yuv420p",
          "-c:a",
          "aac",
          "-shortest",
          path
        ])
    end

    path
  end

  defp wait_until_ready(ids, seconds_left) do
    pending =
      Repo.aggregate(
        from(i in Content.Item, where: i.id in ^ids and i.status == "processing"),
        :count
      )

    cond do
      pending == 0 -> :ok
      seconds_left <= 0 -> Mix.raise("#{pending} videos still processing after 3 minutes")
      true -> Process.sleep(1000) && wait_until_ready(ids, seconds_left - 1)
    end
  end
end
