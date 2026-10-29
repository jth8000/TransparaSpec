defmodule TSpec.Docs.ReviewPacketTest do
  @moduledoc """
  docs/review/ is what outside reviewers read first. Its claims point at
  code, tests and mutations; this keeps every pointer real, so the packet
  can't cite a test that was renamed or a mutation that was dropped.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)
  @review Path.join(@root, "docs/review")
  @mutations Path.join(@root, "scripts/mutation_checks.py")

  defp docs do
    for path <- Path.wildcard(Path.join(@review, "*.md")), do: {path, File.read!(path)}
  end

  test "every relative link in the packet points at a file that exists" do
    missing =
      for {path, text} <- docs(),
          [_, target] <- Regex.scan(~r/\]\(([^)#\s]+)(?:#[^)]*)?\)/, text),
          not String.starts_with?(target, "http"),
          resolved = Path.expand(target, Path.dirname(path)),
          not File.exists?(resolved),
          do: "#{Path.basename(path)} → #{target}"

    assert missing == []
  end

  # ExUnit (`test "…"`, `property "…"`) and Jest (`it('…'`, `it("…"`).
  defp defines_test?(source, name) do
    Enum.any?(
      [~s(test "#{name}"), ~s(property "#{name}"), ~s(it('#{name}'), ~s(it("#{name}")],
      &String.contains?(source, &1)
    )
  end

  test "every cited test exists in the file it's linked to" do
    citations =
      for {path, text} <- docs(),
          [_, file, name] <-
            Regex.scan(~r/\]\(([^)]+(?:_test\.exs|\.test\.tsx?))\):\s*"([^"]+)"/, text),
          do: {Path.expand(file, Path.dirname(path)), name}

    assert length(citations) > 30

    missing =
      for {file, name} <- citations,
          not defines_test?(File.read!(file), name),
          do: "#{Path.relative_to(file, @root)}: #{name}"

    assert missing == []
  end

  test "the invariant tables and scripts/mutation_checks.py cite the same mutations" do
    ids = fn text, regex ->
      regex |> Regex.scan(text) |> Enum.map(&List.last/1) |> MapSet.new()
    end

    in_doc =
      docs()
      |> Enum.map(&elem(&1, 1))
      |> Enum.map(&ids.(&1, ~r/\bM(\d+)\b/))
      |> Enum.reduce(&MapSet.union/2)

    in_script = ids.(File.read!(@mutations), ~r/\("M(\d+) /)

    assert MapSet.size(in_script) > 0
    assert in_doc == in_script
  end
end
