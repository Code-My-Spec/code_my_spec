defmodule CodeMySpec.Analysis.Freshness do
  @moduledoc """
  Whether each analyzer's last run is current for this checkout's code, kept as
  a projection rather than derived on every read.

  ## What it replaces

  `Analysis.fresh?/2` asks `Fingerprint.current/2`, which reads every file row
  for the checkout — ~5,100 on this project — and hashes the subset feeding that
  source. `fresh_sources/2` does it once for all four. The promote gate asks on
  every attempt, and `Preloader.analysis_freshness/2` asks on every graph pass,
  which is the only reason a narrow per-entity load still has to read the whole
  file table.

  None of that is a question about *now*. It is a question about two events that
  already happened — a run finished, and a file it reads changed — and which of
  them came last.

  ## Two events, and the role map decides the second

  A run completing makes its own source fresh. A file changing stales the
  sources that read its role, which `Fingerprint.sources_for_role/1` answers
  from the inverse of the same table `roles/1` reads: an implementation or test
  file stales all four, a `_spex.exs` stales credo and spex but not compiler or
  exunit, a markdown spec or a knowledge doc stales nothing.

  ## Absence means unknown, and that is load-bearing

  A row is flipped, never deleted, so no row means this copy and source have
  never been projected. Readers fall back to the fingerprint comparison rather
  than guessing, which is what makes this safe without a backfill.

  ## What observes the tree

  Not git, and an earlier version of this comment said otherwise. A checkout or
  a branch switch is a lot of files changing at once, and `FileSync` sees it the
  same way it sees one: `changed_entries/2` compares each scanned file against
  its stored row on the replaceable fields, fingerprint included, so every file
  the checkout touched comes back changed and stales what reads it. If the
  harness was down while it happened, the boot scan reports them — the stored
  rows still hold the pre-checkout fingerprints.

  So `rebuild/1` is not covering an unobserved mutation, because there is not
  one. It is the escape hatch for this projection being wrong some other way — a
  bug, a bad backfill, a row written by something that never went through the
  sync — and it is worth having precisely because a stale *clean* row is a false
  pass, the direction that costs correctness rather than time.
  """

  use Ecto.Schema

  import Ecto.Query

  alias CodeMySpec.Analysis.Fingerprint
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @type t :: %__MODULE__{}

  schema "analysis_freshness" do
    field :source, :string
    field :fresh, :boolean
    field :run_id, :integer
    field :fresh_at, :naive_datetime
    field :staled_at, :naive_datetime
    field :staled_by, :string

    belongs_to :working_copy, WorkingCopy, type: :binary_id

    timestamps()
  end

  @doc """
  Record that this source's run answered for the tree as it stands.

  Called when a run completes. The run is named so a reader can say *which*
  answered rather than only that one did.
  """
  @spec mark_fresh(Ecto.UUID.t() | nil, String.t(), Run.t() | nil) :: :ok
  def mark_fresh(working_copy_id, source, run \\ nil)

  def mark_fresh(working_copy_id, source, run)
      when is_binary(working_copy_id) and is_binary(source) do
    now = now()

    upsert(%{
      working_copy_id: working_copy_id,
      source: source,
      fresh: true,
      run_id: run && run.id,
      fresh_at:
        (run && run.finished_at && NaiveDateTime.truncate(run.finished_at, :second)) || now,
      staled_at: nil,
      staled_by: nil,
      inserted_at: now,
      updated_at: now
    })
  end

  def mark_fresh(_no_copy, _source, _run), do: :ok

  @doc """
  Record that a file changed under these sources.

  `path` is kept because a source that is stale with no explanation is the shape
  that costs time to diagnose — the refusal message the promote gate writes can
  name what took it away.

  Only flips rows that exist, and deliberately: a source never projected stays
  unknown so its reader falls back to the comparison, rather than being asserted
  stale by a file change we happen to have seen.
  """
  @spec mark_stale(Ecto.UUID.t() | nil, [String.t()], String.t() | nil) :: :ok
  def mark_stale(working_copy_id, sources, path \\ nil)

  def mark_stale(working_copy_id, [_ | _] = sources, path) when is_binary(working_copy_id) do
    now = now()

    __MODULE__
    |> where([f], f.working_copy_id == ^working_copy_id and f.source in ^sources)
    |> where([f], f.fresh)
    |> Repo.update_all(set: [fresh: false, staled_at: now, staled_by: path, updated_at: now])

    :ok
  end

  def mark_stale(_working_copy_id, _sources, _path), do: :ok

  @doc """
  Stale every source the roles of these files feed.

  The file-side entry point: hand it what a sync changed and it works out which
  analyzers can no longer answer for the tree.
  """
  @spec stale_for_roles(Ecto.UUID.t() | nil, Enumerable.t(), String.t() | nil) :: :ok
  def stale_for_roles(working_copy_id, roles, path \\ nil),
    do: mark_stale(working_copy_id, Fingerprint.sources_for_roles(roles), path)

  @doc """
  What this projection knows, as `%{source => fresh?}`.

  Only sources with a row. A caller merges this over whatever it computes, so an
  unprojected source is answered the old way rather than guessed at.
  """
  @spec known(Ecto.UUID.t() | nil) :: %{String.t() => boolean()}
  def known(working_copy_id) when is_binary(working_copy_id) do
    __MODULE__
    |> where([f], f.working_copy_id == ^working_copy_id)
    |> select([f], {f.source, f.fresh})
    |> Repo.all()
    |> Map.new()
  end

  def known(_no_copy), do: %{}

  @doc "One source, or `nil` when this copy and source have never been projected."
  @spec known(Ecto.UUID.t() | nil, String.t()) :: boolean() | nil
  def known(working_copy_id, source) when is_binary(working_copy_id),
    do: known(working_copy_id) |> Map.get(source)

  def known(_no_copy, _source), do: nil

  @doc """
  Re-establish truth from the files themselves, and record it.

  The escape hatch, and the reason the fingerprint comparison is not deleted.
  Not because the tree can change unobserved — `FileSync` reports a checkout's
  files the same as any other change, and the boot scan covers the window where
  nothing was watching — but because a projection can be wrong for reasons its
  own events cannot describe. This is the comparison the read path used to run
  on every call, available where it is asked for deliberately.
  """
  @spec rebuild(Scope.t()) :: %{String.t() => boolean()}
  def rebuild(%Scope{active_working_copy_id: working_copy_id} = scope)
      when is_binary(working_copy_id) do
    fingerprints = Fingerprint.current(scope)

    Map.new(Run.sources(), fn source ->
      fresh? = current?(scope, source, Map.get(fingerprints, source))
      record(working_copy_id, source, fresh?)
      {source, fresh?}
    end)
  end

  def rebuild(%Scope{}), do: %{}

  defp current?(scope, source, fingerprint) do
    case RunsRepository.latest_completed_run(scope, source) do
      %Run{} = run ->
        is_binary(fingerprint) and
          (run.input_fingerprint == fingerprint or run.completed_fingerprint == fingerprint)

      _ ->
        false
    end
  end

  defp record(working_copy_id, source, true), do: mark_fresh(working_copy_id, source, nil)

  defp record(working_copy_id, source, false) do
    now = now()

    upsert(%{
      working_copy_id: working_copy_id,
      source: source,
      fresh: false,
      run_id: nil,
      fresh_at: nil,
      staled_at: now,
      staled_by: "rebuilt from file fingerprints",
      inserted_at: now,
      updated_at: now
    })
  end

  defp upsert(row) do
    Repo.insert_all(__MODULE__, [row],
      on_conflict: {:replace, [:fresh, :run_id, :fresh_at, :staled_at, :staled_by, :updated_at]},
      conflict_target: [:working_copy_id, :source]
    )

    :ok
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
