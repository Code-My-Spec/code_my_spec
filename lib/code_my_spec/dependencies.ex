defmodule CodeMySpec.Dependencies do
  @moduledoc """
  What a project depends on, and which of those have had their docs projected.

  ## Why this is persisted at all

  Hexdoc embedding used to be driven by a filesystem event: poll `mix.lock`'s
  mtime, notice it moved, wait ten seconds for `mix deps.get` to finish
  unpacking, then glob `deps/<pkg>/lib/**/*.ex`. The ten seconds were a guess
  standing in for a signal that does not exist, and a guess like that holds until
  the machine is slower than the guess — a cold cache, a big dependency set, a
  loaded CI box. When it loses, the projector reads a half-unpacked tree, embeds
  whatever happened to be there, and reports success. Nothing downstream can tell
  that from a project whose deps genuinely contain that much.

  Recording the dependency set removes the race rather than widening the window.
  The lock is written before unpacking starts and is complete when written, so it
  can be recorded the moment it changes with nothing to wait out. Projection then
  becomes a **convergence** over recorded state: work the packages whose
  `projected_version` does not match their `version`, leave the ones whose source
  is not on disk yet, and run again. That has an end state — `pending/1` returns
  `[]` — which is something a caller can wait for, retry toward, and assert on.

  ## Recording is all-or-nothing

  `record_lockfile/2` takes the whole parsed lock. A partial set is
  indistinguishable from a project that dropped the rest of its dependencies, and
  acting on it would delete their projected docs. Same reasoning as the file
  manifest in `HarnessProjectChannel`: the complete set is what makes the result
  verifiable.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Projects, CodeMySpec.Repo, CodeMySpec.Users],
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
  Packages whose version is unchanged keep their `projected_version`, so
  re-recording an unchanged lock leaves nothing pending — which is what makes
  this safe to call on every lock event rather than only on ones believed to be
  real.

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

  @doc """
  Dependencies whose docs are not projected at their recorded version.

  An empty list is the convergence condition: every recorded package has had its
  documentation projected at the version currently pinned.
  """
  @spec pending(Scope.t()) :: [Dependency.t()]
  def pending(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Repo.all(
      from d in Dependency,
        where: d.project_id == ^project_id,
        where: is_nil(d.projected_version) or d.projected_version != d.version,
        order_by: d.name
    )
  end

  @doc """
  Record that `name`'s docs are projected at `version`.

  Takes the version explicitly rather than copying the current `version` column,
  so a package that was re-pinned while its docs were being projected is not
  marked current for a version nobody projected. It stays pending and the next
  pass picks it up.
  """
  @spec mark_projected(Scope.t(), String.t(), String.t() | nil) :: :ok
  def mark_projected(%Scope{active_project_id: project_id}, name, version)
      when is_binary(project_id) and is_binary(name) do
    {_count, _} =
      Repo.update_all(
        from(d in Dependency,
          where: d.project_id == ^project_id and d.name == ^name and d.version == ^version
        ),
        set: [projected_version: version, updated_at: DateTime.utc_now(:second)]
      )

    :ok
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
          inserted_at: now,
          updated_at: now
        }
      end)

    recorded =
      case rows do
        [] ->
          0

        _ ->
          # `projected_version` is deliberately absent from the update set: a
          # package whose pin did not move keeps its projected docs, and one
          # whose pin did move is left pointing at the old version, which is
          # exactly what makes it show up in `pending/1`.
          rows
          |> Enum.chunk_every(@upsert_chunk_size)
          |> Enum.reduce(0, fn chunk, acc ->
            {count, _} =
              Repo.insert_all(Dependency, chunk,
                on_conflict: {:replace, [:version, :source, :updated_at]},
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
