defmodule CodeMySpec.Requirements.DelegateFiles do
  @moduledoc """
  Digests the working-copy files that delegate checkers read and the file sync
  does not track.

  ## Why this is not already covered

  `GraphFingerprint` hashes `files_by_project`, which is every file the scanner
  synced. `AgentTasks.QaIntegrationPlan` globs `.code_my_spec/integrations/*.md`
  and those never get there.

  `.code_my_spec` is in `Scanner`'s sync roots, so the walker descends into that
  directory — but `Scanner.classify/1` does not claim integration specs, and
  `stream_files/1` drops what classify does not claim. They are walked past,
  every time. The harness says so out loud on every scan ("N file(s) ... match
  no role and are NOT synced"); these are among that N.

  So an integration spec could be written or verified and nothing the
  fingerprint watched would have moved.

  This covered three more locations until the devops requirements came out of
  the graph — deploy records, the releases directory and the devops setup
  record, read by `deploy`, `release` and `devops_setup`. Those requirements are
  gone, so nothing reads those files for the graph any more.

  ## Why a digest rather than making them sync

  Teaching `classify/1` about them is the better long-term answer — they would
  become `File` rows, the existing digest would cover them, and the checkers
  could eventually read the database instead of the disk. It is also a change
  to what the Files table contains and what `validate_entry/4` must say about a
  new role, which is a wider blast radius than this needs.

  This reads exactly what the checkers read and nothing else. It is a few
  directory listings and a handful of small markdown files.

  ## No working copy, nothing to digest

  On the light harness the server holds no working copy, so `scope.environment`
  is nil, `Environments.read_file/2` answers `{:error, :no_environment}`, and
  these checkers report unsatisfied for every project alike. There is nothing
  to hash and nothing that can change, so the digest is a constant — correct
  rather than merely convenient.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Paths

  @doc """
  A stable digest of every working-copy file a delegate check reads.

  `:no_working_copy` when the scope has no environment.
  """
  @spec digest(struct()) :: term()
  def digest(%{environment: nil}), do: :no_working_copy

  def digest(%{environment: env}) do
    [glob_digest(env, Path.join(Paths.integrations_dir(), "*.md"))]
  end

  def digest(_scope), do: :no_working_copy

  # Contents, not just names: `QaIntegrationPlan` checks whether each spec
  # records a verified status, so a file rewritten in place from unverified to
  # verified changes nothing a listing would see.
  defp glob_digest(env, pattern) do
    env
    |> Environments.glob(pattern)
    |> Enum.sort()
    |> Enum.map(&file_digest(env, &1))
  end

  defp file_digest(env, path) do
    case Environments.read_file(env, path) do
      {:ok, content} -> {path, :crypto.hash(:sha256, content)}
      _ -> {path, :absent}
    end
  end
end
