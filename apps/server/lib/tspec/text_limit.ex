defmodule TSpec.TextLimit do
  @bytes_per_grapheme 16

  @moduledoc """
  Length limits on text people write: captions, post bodies, display names
  and bios.

  A limit counts graphemes, what a reader sees as one character
  (`String.length/1`, as Ecto's `validate_length/3` and OpenApiSpex's
  `maxLength` both count), so it agrees with the counter the client shows.
  A grapheme has no size of its own, though: one can carry any number of
  combining marks ("Zalgo" text). Counted only in graphemes, a 300-character
  bio could fill the whole request body, be stored, and be sent to everyone
  who views the profile.

  So each limit also caps the text at #{@bytes_per_grapheme} bytes per
  grapheme. No natural text gets near that: an emoji with a skin tone takes
  8 bytes, and the densest scripts about 9 (Korean typed as separate jamo,
  which is how some keyboards and macOS send it).
  """
  import Ecto.Changeset

  def bytes_per_grapheme, do: @bytes_per_grapheme

  @doc """
  `validate_length/3` in graphemes (takes `:max`, and `:min` if given), plus
  a cap of `max * #{@bytes_per_grapheme}` bytes.
  """
  def validate(changeset, field, opts) do
    max = Keyword.fetch!(opts, :max)

    changeset
    |> validate_length(field, opts)
    |> validate_length(field, max: max * @bytes_per_grapheme, count: :bytes)
  end
end
