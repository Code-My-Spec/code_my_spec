defmodule CodeMySpec.Dependencies do
  @moduledoc """
  What a project depends on, recorded from its main copy's `mix.lock`
  (`FileSync.reconcile_lockfile/1`). `HexDocReconciler` embeds the exact
  `package@version` pairs recorded here, and search scopes hex docs to them.

  ## Recording is all-or-nothing

  `record_lockfile/2` takes the whole parsed lock. A partial set is
  indistinguishable from a project that dropped the rest of its dependencies, and
  acting on it would drop their docs from search. Same reasoning as the file
  manifest in `HarnessProjectChannel`: the complete set is what makes the result
  verifiable.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Projects, CodeMySpec.Repo, CodeMySpec.Users, CodeMySpec.Users.Scope],
    exports: :all

  import Ecto.Query, warn: false

  # Matches Files.upsert_files/2 — SQLite's bound-parameter ceiling is the
  # binding constraint, not Postgres.
  @upsert_chunk_size 500

  alias CodeMySpec.Dependencies.Dependency
  alias CodeMySpec.Dependencies.Lockfile
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  Record a project's dependency set from `mix.lock` contents.

  Upserts every package in the lock and removes the ones no longer in it.

  Returns `{:error, :unparseable}` without touching anything if the lock cannot
  be read. An unreadable lock says nothing about what the project depends on, so
  it must not be allowed to say "nothing".
  """
  @spec record_lockfile(Scope.t(), String.t()) ::
          {:ok, %{recorded: non_neg_integer(), removed: non_neg_integer()}}
          | {:error, :unparseable}
  def record_lockfile(%Scope{active_project_id: project_id}, contents)
      when is_binary(project_id) do
    with {:ok, entries} <- Lockfile.parse(contents) do
      {:ok, record_entries(project_id, entries)}
    end
  end

  @doc """
  Every dependency recorded for this project.
  """
  @spec list_dependencies(Scope.t()) :: [Dependency.t()]
  def list_dependencies(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Repo.all(from d in Dependency, where: d.project_id == ^project_id, order_by: d.name)
  end

  # -- Internals --

  defp record_entries(project_id, entries) do
    now = DateTime.utc_now(:second)

    rows =
      Enum.map(entries, fn entry ->
        %{
          id: Ecto.UUID.generate(),
          project_id: project_id,
          name: entry.name,
          version: entry.version,
          source: entry.source,
          checksum: entry.checksum,
          inserted_at: now,
          updated_at: now
        }
      end)

    recorded =
      case rows do
        [] ->
          0

        _ ->
          rows
          |> Enum.chunk_every(@upsert_chunk_size)
          |> Enum.reduce(0, fn chunk, acc ->
            {count, _} =
              Repo.insert_all(Dependency, chunk,
                on_conflict: {:replace, [:version, :source, :checksum, :updated_at]},
                conflict_target: [:project_id, :name]
              )

            acc + count
          end)
      end

    names = Enum.map(entries, & &1.name)

    {removed, _} =
      Repo.delete_all(
        from d in Dependency,
          where: d.project_id == ^project_id and d.name not in ^names
      )

    %{recorded: recorded, removed: removed}
  end
end
