# The ffmpeg-backed LocalProvider integration test needs ffmpeg/ffprobe.
exclude = if System.find_executable("ffmpeg"), do: [], else: [:ffmpeg]

# assert_receive waits up to 1s (default 100ms): pushes cross PubSub and a
# channel process, and on a loaded CI runner that has taken over 100ms. A
# passing assertion returns as soon as the message arrives, and
# refute_receive keeps its own 100ms default.
ExUnit.start(exclude: exclude, assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(TSpec.Repo, :manual)
