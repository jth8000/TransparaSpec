# The ffmpeg-backed LocalProvider integration test needs ffmpeg/ffprobe.
exclude = if System.find_executable("ffmpeg"), do: [], else: [:ffmpeg]

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(TSpec.Repo, :manual)
