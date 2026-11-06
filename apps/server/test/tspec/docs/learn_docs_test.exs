defmodule TSpec.Docs.LearnDocsTest do
  @moduledoc """
  docs/learn/ walks through real code and gives exercises that call it.
  Keeps its links, the `Session.function/arity` references the exercises
  call, and the tests it cites real, so the walkthrough can't drift.
  """
  use ExUnit.Case, async: true

  @learn Path.expand("../../../../../docs/learn", __DIR__)

  defp docs do
    for path <- Path.wildcard(Path.join(@learn, "*.md")), do: {path, File.read!(path)}
  end

  test "every relative link points at a file that exists" do
    missing =
      for {path, text} <- docs(),
          [_, target] <- Regex.scan(~r/\]\(([^)#\s]+)(?:#[^)]*)?\)/, text),
          not String.starts_with?(target, "http"),
          not File.exists?(Path.expand(target, Path.dirname(path))),
          do: "#{Path.basename(path)} → #{target}"

    assert missing == []
  end

  test "every Session.function/arity it names is a public function" do
    Code.ensure_loaded!(TSpec.Feed.Session)

    named =
      for {_path, text} <- docs(),
          [_, fun, arity] <- Regex.scan(~r/\bSession\.(\w+[?!]?)\/(\d)/, text),
          uniq: true,
          do: {String.to_atom(fun), String.to_integer(arity)}

    assert named != []
    assert Enum.reject(named, fn {f, a} -> function_exported?(TSpec.Feed.Session, f, a) end) == []
  end

  test "every cited test exists in the file it's linked to" do
    missing =
      for {path, text} <- docs(),
          [_, file, name] <- Regex.scan(~r/\]\(([^)]+_test\.exs)\):\s*"([^"]+)"/, text),
          source = File.read!(Path.expand(file, Path.dirname(path))),
          not String.contains?(source, ~s(test "#{name}")),
          do: "#{file}: #{name}"

    assert missing == []
  end
end
