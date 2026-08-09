defmodule CodeMySpec.Analysis.Coverage do
  @moduledoc """
  What each analyzer has looked at, and whether it still holds.

  Reads and writes `FileAnalysis` rows. Nothing consumes this yet — it is built
  additively so it can be verified against a real project before anything starts
  deciding with it.

  ## The two questions

  `stale_files/2` — which files this source covered have changed since it read
  them. Empty means fresh. Non-empty *names the files*, which is the thing the
  stop hook has never been able to say: today it reports that something changed,
  not what.

  `unanalyzed_files/2` — which files with feeding roles have no coverage row at
  all. This is the one that closes the invariant. `tests_passing` and
  `no_problems` are `count == 0`; without this they read "clean" from an absence
  and cannot tell a clean file from an unlooked-at one.

  ## Why not a whole-corpus hash

  `Fingerprint.current/2` answers "has anything changed" with one hash. For an
  analyzer slower than the edit rate that is permanently true — exunit takes
  ~2m20s here and an agent edits every couple of minutes, so its result is never
  at the current fingerprint and its findings are always labelled stale
  (7a7eed33). No hashing scheme fixes that; the question is wrong. Per-file
  coverage asks a question that has a useful answer even when the corpus is
  moving.
  """

  import Ecto.Query

  alias CodeMySpec.Analysis.FileAnalysis
  alias CodeMySpec.Analysis.Fingerprint
  alias CodeMySpec.Files.File, as: ProjectFile
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  Record what a run read.

  `entries` are `{file_id, fingerprint}` — the content the analyzer *saw*, which
  is why it is passed in rather than read from `files` here. Reading it here
  would stamp the current content onto a file whose older bytes the tool
  actually read, which is a false fact rather than a stale one.

  Upserts on `(harness_id, file_id, source)`: only current coverage is a fact
  anyone asks about, and a row per file per run would be hundreds of thousands a
  day per working copy.
  """
  @spec record(Scope.t(), String.t(), [{Ecto.UUID.t(), String.t()}], keyword()) ::
          {non_neg_integer(), nil}
  def record(%Scope{} = scope, source, entries, opts \\ []) when is_list(entries) do
    now = DateTime.utc_now()
    analyzed_at = Keyword.get(opts, :analyzed_at, now)
    run_id = Keyword.get(opts, :run_id)
    stamped = DateTime.truncate(now, :second)

    rows =
      for {file_id, fingerprint} <- entries, is_binary(fingerprint) and fingerprint != "" do
        %{
          id: Ecto.UUID.generate(),
          file_id: file_id,
          project_id: scope.active_project_id,
          harness_id: scope.active_harness_id,
          source: source,
          fingerprint: fingerprint,
          analyzed_at: analyzed_at,
          run_id: run_id,
          inserted_at: stamped,
          updated_at: stamped
        }
      end

    Repo.insert_all(FileAnalysis, rows,
      on_conflict: {:replace, [:fingerprint, :analyzed_at, :run_id, :updated_at]},
      conflict_target: [:harness_id, :file_id, :source]
    )
  end

  @doc """
  Files this source covered whose content has moved since.

  Empty means every file it read still has the bytes it read. Non-empty is the
  answer to "why is this stale", per file.
  """
  @spec stale_files(Scope.t(), String.t()) :: [ProjectFile.t()]
  def stale_files(%Scope{} = scope, source) do
    scope
    |> covered_query(source)
    |> where([f, a], f.fingerprint != a.fingerprint)
    |> select([f, _a], f)
    |> Repo.all()
  end

  @doc """
  Files whose role feeds this source and which it has never read.

  No row is not "clean" — it is "nobody looked", and those must not be the same
  answer.
  """
  @spec unanalyzed_files(Scope.t(), String.t()) :: [ProjectFile.t()]
  def unanalyzed_files(%Scope{} = scope, source) do
    scope
    |> feeding_files(source)
    |> join(:left, [f], a in FileAnalysis,
      on: a.file_id == f.id and a.source == ^source and a.harness_id == ^scope.active_harness_id
    )
    |> where([_f, a], is_nil(a.id))
    |> select([f, _a], f)
    |> Repo.all()
  end

  @doc """
  Fresh when nothing it read has changed **and** nothing it should read is
  unread.

  Both halves are required. Covered-and-unchanged alone would call a source
  fresh that has never seen half the project — which is the absence reading as
  good news that this whole table exists to prevent.
  """
  @spec fresh?(Scope.t(), String.t()) :: boolean()
  def fresh?(%Scope{} = scope, source) do
    stale_files(scope, source) == [] and unanalyzed_files(scope, source) == []
  end

  defp covered_query(%Scope{} = scope, source) do
    scope
    |> feeding_files(source)
    |> join(:inner, [f], a in FileAnalysis,
      on: a.file_id == f.id and a.source == ^source and a.harness_id == ^scope.active_harness_id
    )
  end

  # The roles that feed a source are `Fingerprint`'s, unchanged — one definition
  # of "what this analyzer reads", used by both the hash and the coverage.
  defp feeding_files(%Scope{} = scope, source) do
    roles = Fingerprint.roles(source)

    ProjectFile
    |> where([f], f.project_id == ^scope.active_project_id)
    |> where([f], f.harness_id == ^scope.active_harness_id)
    |> where([f], f.role in ^roles)
  end
end
