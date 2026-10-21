defmodule CodeMySpec.SqliteMigrationsTest do
  @moduledoc """
  The desktop runs on SQLite from `priv/sqlite`: a baseline of the Postgres
  schema, then a counterpart for every Postgres migration after it. A Postgres
  migration with no counterpart is a desktop whose schema is behind.
  """

  use ExUnit.Case, async: true

  test "every Postgres migration after the SQLite baseline has a SQLite counterpart" do
    sqlite = versions("priv/sqlite/migrations")
    baseline = Enum.min(sqlite)

    missing =
      "priv/repo/migrations"
      |> versions()
      |> Enum.filter(&(&1 > baseline))
      |> Enum.reject(&(&1 in sqlite))

    assert missing == [],
           "Postgres migrations with no counterpart in priv/sqlite/migrations " <>
             "(same version; most copy over unchanged): #{inspect(missing)}"
  end

  defp versions(dir) do
    dir
    |> File.ls!()
    |> Enum.map(&(&1 |> String.split("_", parts: 2) |> hd() |> String.to_integer()))
  end
end
