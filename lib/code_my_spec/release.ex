defmodule CodeMySpec.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  use Boundary, top_level?: true, deps: [CodeMySpec.Utils], exports: :all

  alias CodeMySpec.Utils.Data

  @app :code_my_spec

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def import_project(file_path, opts \\ []) do
    load_app()
    Application.ensure_all_started(@app)

    # Raised rather than returned, because this is the boundary a shell script
    # calls through `bin/code_my_spec eval`. A refusal handed back as a tuple
    # exits 0, and sync-project.sh reports a successful migration over an import
    # that declined to run.
    case Data.import_project(file_path, opts) do
      {:error, reason} -> raise Data.explain(reason)
      result -> result
    end
  end

  def export_project(project_id, file_path) do
    load_app()
    Application.ensure_all_started(@app)
    Data.export_project(project_id, file_path)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
