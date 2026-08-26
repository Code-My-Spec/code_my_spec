defmodule Mix.Tasks.Sync.Data do
  @shortdoc "Export or import one project's data for scripts/sync-project.sh"

  @moduledoc """
  The local-dev half of `scripts/sync-project.sh` — the remote half runs the
  same `CodeMySpec.Utils.Data` functions through `CodeMySpec.Release` over
  `fly ssh`, where Mix isn't installed.

      mix sync.data export --project-id <id> --output <path>
      mix sync.data import --file <path> [--dry-run]

  Moves exactly one project: its own row, its components, and its
  stories/versions. Never the account, its members, its users, or any other
  project the account owns — see `CodeMySpec.Utils.Data`'s moduledoc.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias CodeMySpec.Utils.Data

  @impl Mix.Task
  def run(["export" | rest]) do
    start_repo()

    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [project_id: :string, output: :string])

    project_id = Keyword.fetch!(opts, :project_id)
    output = Keyword.fetch!(opts, :output)

    Data.export_project(project_id, output)
  end

  def run(["import" | rest]) do
    start_repo()

    {opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: [file: :string, dry_run: :boolean])

    file = Keyword.fetch!(opts, :file)
    dry_run = Keyword.get(opts, :dry_run, false)

    Data.import_project(file, dry_run: dry_run)
  end

  def run(_args) do
    Mix.shell().info("""
    Usage:
      mix sync.data export --project-id <id> --output <path>
      mix sync.data import --file <path> [--dry-run]
    """)
  end

  # Only Repo (and what it needs), never Mix.Task.run("app.start") — this
  # runs against local dev while `mix phx.server` already owns :4000, and
  # starting the full OTP app tries to bind the Endpoint a second time and
  # crashes on :eaddrinuse instead of doing the one thing this task needs.
  defp start_repo do
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:cloak)

    case CodeMySpec.Vault.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case CodeMySpec.Repo.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
