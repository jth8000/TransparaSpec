defmodule TSpecWeb.ChangesetErrors do
  @moduledoc "Turns changeset errors into a `%{field => [message]}` map for JSON responses."

  def to_map(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
