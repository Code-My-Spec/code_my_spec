defmodule Mix.Tasks.Cms.DropTestDatabase do
  @shortdoc "Drop this checkout's test database, and nothing but a test database"

  @moduledoc """
  Drop the test database `MIX_TEST_PARTITION` names.

      MIX_ENV=test MIX_TEST_PARTITION=<partition> mix cms.drop_test_database

  The promotion gate runs this for its own databases before each candidate
  (`CodeMySpec.Promotion.Steps.reset_test_databases/3`): `ecto.migrate` only
  goes forward, so a candidate the gate ejected left its migrations behind, and
  the next candidate failed 749 tests on a schema it never had (2026-10-11).
  The next run's `ecto.create` and `ecto.migrate` rebuild it.

  ## It drops nothing but a test database

  Run in this VM against `CodeMySpec.Repo.config()` — a child given an
  environment with `MIX_ENV` scrubbed once created "test" databases in dev
  (2026-08-13). It refuses unless `MIX_ENV=test` and the database is named as a
  test database: `CMS_DRILL_DB` points the test config at `code_my_spec_dev`.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:postgrex)
    config = CodeMySpec.Repo.config()

    with :ok <- droppable(config, Mix.env()),
         :ok <- drop(config) do
      IO.puts("dropped #{config[:database]}")
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc "Whether this VM may drop the database `config` names."
  @spec droppable(keyword(), atom()) :: :ok | {:error, String.t()}
  def droppable(config, env) do
    database = config[:database]

    cond do
      env != :test ->
        {:error, "refusing to drop a database from MIX_ENV=#{env}; only :test drops one"}

      not (is_binary(database) and String.contains?(database, "_test")) ->
        {:error, "refusing to drop #{inspect(database)}: not named as a test database"}

      true ->
        :ok
    end
  end

  # Forced: a run the gate abandoned can still hold connections to it.
  defp drop(config) do
    case CodeMySpec.Repo.__adapter__().storage_down(Keyword.put(config, :force_drop, true)) do
      :ok -> :ok
      {:error, :already_down} -> :ok
      {:error, reason} -> {:error, "could not drop #{config[:database]}: #{inspect(reason)}"}
    end
  end
end
