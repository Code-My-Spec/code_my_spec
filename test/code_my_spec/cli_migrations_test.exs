defmodule CodeMySpec.CliMigrationsTest do
  @moduledoc """
  The CLI migration set has to be runnable against an empty SQLite database.

  `CodeMySpecLocalWeb.Migrator` is a child of the application supervisor, so a
  migration that cannot run does not get skipped — it stops the app from
  starting:

      ** (Mix) Could not start application code_my_spec:
         CodeMySpecLocalWeb.Application.start(:normal, []) returned an error:
         shutdown: failed to start child: CodeMySpecLocalWeb.Migrator

  And it is invisible until someone makes a fresh database or an existing one
  catches up, because a database *behind* the bad migration never reaches it.
  That is the whole shape of the failure: it ships green and breaks on install.

  Three have now been found this way, all mirrored from the server set without
  the CLI needing them:

    * `61351c19` — Postgres-only `split_part`/`::integer` in a backfill
    * `ca46f606` — altered `question_requests`, never created here
    * this test's case — altered `conversation_messages` and `conversations`,
      neither created here, both dated 2026-08-14 and both found by running a
      fresh boot rather than by review

  So the rule is checked rather than remembered. This is a structural check on
  the files: it does not need a database, so it runs everywhere and costs
  nothing.
  """

  use ExUnit.Case, async: true

  @cli_dir "priv/repo/cli_migrations"

  # `create table(:x)` and `create_if_not_exists table(:x)` are the Ecto DSL;
  # `CREATE TABLE x (` is the raw-SQL form, which `doc_embeddings` uses and
  # which a DSL-only scan reports as a false positive. Both count.
  defp tables_created(source) do
    dsl = Regex.scan(~r/create(?:_if_not_exists)?\s+table\(:(\w+)/, source)
    raw = Regex.scan(~r/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)/i, source)

    for [_, name] <- dsl ++ raw, into: MapSet.new(), do: name
  end

  defp tables_altered(source) do
    for [_, name] <- Regex.scan(~r/alter\s+table\(:(\w+)/, source),
        into: MapSet.new(),
        do: name
  end

  defp cli_sources do
    @cli_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.sort()
    |> Enum.map(&{&1, File.read!(Path.join(@cli_dir, &1))})
  end

  test "no CLI migration alters a table the CLI set never creates" do
    {created, altered} =
      Enum.reduce(cli_sources(), {MapSet.new(), %{}}, fn {name, source}, {created, altered} ->
        {
          MapSet.union(created, tables_created(source)),
          Enum.reduce(tables_altered(source), altered, fn table, acc ->
            Map.update(acc, table, [name], &[name | &1])
          end)
        }
      end)

    orphans =
      altered
      |> Enum.reject(fn {table, _files} -> MapSet.member?(created, table) end)
      |> Enum.sort()

    assert orphans == [],
           """
           These CLI migrations alter a table the CLI set never creates:

           #{Enum.map_join(orphans, "\n", fn {table, files} -> "  #{table} — #{Enum.join(files, ", ")}" end)}

           A migration mirrored from the server set brings the server's schema
           assumptions with it. `CodeMySpecLocalWeb.Migrator` is supervised, so
           this is not a skipped migration — the app will not start, for every
           existing CLI user as well as every fresh install, and the database is
           only reachable through the app.

           Either mirror the migration that creates the table, or — if the CLI
           does not use that table — do not mirror the alter. Check whether
           anything under `lib/code_my_spec_local_web` or `lib/cms_harness`
           references it before adding tables the CLI will never read.
           """
  end

  # Postgres-only SQL is the same failure by a different route: `61351c19`
  # shipped `split_part(...)` and a `::integer` cast into SQLite and took the
  # app down with `unrecognized token: ":"`.
  @postgres_only ~w(split_part jsonb ILIKE SERIAL RETURNING gen_random_uuid)

  test "no CLI migration uses Postgres-only SQL" do
    offenders =
      for {name, source} <- cli_sources(),
          fragment <- @postgres_only,
          String.contains?(source, fragment),
          # Prose explaining why the construct is absent is not a use of it.
          not documentation_only?(source, fragment),
          do: {name, fragment}

    assert offenders == [],
           """
           These CLI migrations contain Postgres-only SQL:

           #{Enum.map_join(offenders, "\n", fn {name, frag} -> "  #{name} — #{frag}" end)}

           SQLite has none of these. The CLI database mirrors server data rather
           than deriving it, so a backfill here computes a second answer to a
           question already settled upstream — usually the right fix is to drop
           the backfill from the mirror and keep the schema change.
           """
  end

  # Both migrations that survived this file's first run mentioned their
  # Postgres construct only to say it had been removed — one in a `#` comment,
  # one in a `@moduledoc`. That is the opposite of the defect and must not read
  # as it, so this strips prose before matching rather than matching line
  # prefixes: the moduledoc form has no prefix to match on.
  defp documentation_only?(source, fragment) do
    source |> strip_prose() |> String.contains?(fragment) |> Kernel.not()
  end

  defp strip_prose(source) do
    source
    |> String.replace(~r/@(module)?doc\s+"""(?s).*?"""/, "")
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.join("\n")
  end
end
