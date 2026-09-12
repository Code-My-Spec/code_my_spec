defmodule CodeMySpec.Promotion.Steps do
  @moduledoc """
  The three things a promotion does to a disk, and nothing else.

  Extracted because they are the only part that cannot happen on the server. A
  project's checkout is on someone else's machine, `scope.environment` is a
  harness environment, and `Environments.Harness.cmd/4` answers
  `{:error, :not_supported_on_harness}` on purpose — it carries file operations
  to the disk, not commands.

  So the gate stays on the server, where the database is, and these run wherever
  the checkout is. `Promotion.Runner` picks: `Runner.Local` calls straight into
  here, `Runner.Harness` sends the same three operations down the channel to be
  answered by this module on the far side.

  Three named operations rather than one `promote`, because the server has to
  look at the database *between* the merge and the restart — `gate_target/3`
  asks whether the merge carried problems into the copy QA tests, and a merge
  that broke the target must not be served. One atomic op would have to either
  skip that check or move it after the restart, and after is too late.

  Three named operations rather than a general `cmd`, because that route was
  refused deliberately: `analysis/run` already owns command execution on the
  harness along with the run ledger, single-flight and `_build`, and a second
  way to run a command there would drift from it.
  """

  alias CodeMySpec.Environments

  @type result :: {:ok, term()} | {:error, map()}

  @doc """
  Whether this checkout has uncommitted work, and what branch it is on.

  Both in one operation because they are one question — "what is here, and is it
  safe to move?" — and because a round trip to another machine is not free.

  Refused before the merge rather than cleaned up after: an aborted half-merge
  leaves the running checkout in a state nobody asked for, and the agent then
  has two problems instead of one.

  `--untracked-files=no`, matching what the gate measures and for the reason
  the gate already documents: refusing on untracked files means refusing
  essentially always, which is the same as not having the check. A build is
  made of what is committed and what is modified, not of scratch files beside
  them.

  Without it the two disagreed, and the disagreement was a trap rather than an
  inconsistency. `code_on_running_copy` passed a checkout whose only dirt was
  untracked, told the agent its remedy was `promote`, and `promote` then refused
  that same checkout — measured on Broken Oaths, where an untracked
  `code_my_spec_test_repos` directory belonging to nobody on the team would have
  blocked every promotion from that copy forever.
  """
  @spec precheck(Environments.Environment.t(), String.t()) :: result()
  def precheck(env, root) do
    case git(env, root, ["status", "--porcelain", "--untracked-files=no"]) do
      {"", 0} -> branch(env, root)
      {dirty, 0} -> uncommitted(dirty)
      {out, _} -> {:error, %{reason: "could not read this checkout's state: #{String.trim(out)}"}}
    end
  end

  defp uncommitted(dirty) do
    {:error,
     %{
       reason: "this copy has uncommitted work. Commit it, then promote.",
       dirty: String.trim_trailing(dirty)
     }}
  end

  defp branch(env, root) do
    case git(env, root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {branch, 0} ->
        {:ok, %{branch: String.trim(branch), untracked: untracked(env, root)}}

      {out, _} ->
        {:error, %{reason: "could not read this checkout's branch: #{String.trim(out)}"}}
    end
  end

  # Reported, not refused, and the distinction is the whole point.
  #
  # An untracked file can be a source file somebody forgot to `git add`, and
  # promoting without it puts QA in front of an application missing the work it
  # was sent to verify — the failure this story exists to prevent. So it must
  # not be silent.
  #
  # It must not block either. `tree_dirty` is measured with
  # `--untracked-files=no`, so a checkout whose only dirt is untracked passes
  # the gate, and the gate's remedy is `promote`. A `promote` that refused what
  # the gate had just waved through would be one system handing an agent two
  # contradictory instructions — and the thing blocking it here was a symlink
  # pointing outside the repository, which is nobody's to commit.
  #
  # Naming them in the result gets the warning without the contradiction.
  defp untracked(env, root) do
    case git(env, root, ["ls-files", "--others", "--exclude-standard"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.take(20)
      _ -> []
    end
  end

  @doc """
  Merge `branch` into the checkout at `root`.

  A conflict is a question about intent, and the agent that wrote one side is
  the only party holding the answer. So this does not guess, and does not
  `--abort` either: the conflict stays in the running checkout where it can be
  resolved. Aborting would be the tidier-looking failure and the worse one — the
  agent is told "promotion failed", finds a clean tree, and has nothing to work
  on.

  Checked for a merge already in progress before attempting a new one. Git
  refuses outright when one is — "you have not concluded your merge" — and
  that refusal used to be read the same way a fresh conflict is: `status
  --porcelain` re-run against whatever files that refusal happened to leave
  behind, named as though this merge had just produced them. A conflict
  resolved in content but never staged reads as a clean tree to `--porcelain`,
  so the message pointed at a file with nothing wrong with it, hours after the
  promotion that actually caused it (e17d3946).
  """
  @spec merge(Environments.Environment.t(), String.t(), String.t()) :: result()
  def merge(env, root, branch) do
    case merge_in_progress(env, root) do
      nil ->
        case git(env, root, ["merge", "--no-edit", branch]) do
          {out, 0} -> {:ok, %{output: String.trim(out)}}
          {out, _} -> conflict(env, root, branch, out)
        end

      info ->
        {:error, %{reason: stale_merge_reason(root, info), stale_merge: true}}
    end
  end

  # `-q --verify` answers with the target sha and exit 0 when `MERGE_HEAD`
  # exists, non-zero otherwise — a plumbing check rather than a guess from
  # `status`, which does not surface merge-in-progress state at all when there
  # is nothing left to stage.
  defp merge_in_progress(env, root) do
    case git(env, root, ["rev-parse", "-q", "--verify", "MERGE_HEAD"]) do
      {sha, 0} -> %{sha: String.trim(sha), since: merge_head_mtime(env, root)}
      _ -> nil
    end
  end

  # `since` is best-effort. `--git-path` resolves where `MERGE_HEAD` actually
  # lives — inside `.git/worktrees/<name>/` for a worktree, not `.git/`
  # directly — so a hardcoded path would answer wrong for exactly the checkouts
  # this module runs against. `nil` on any failure: the sha alone is still an
  # actionable answer, and this is a nicety on top of it, not the fix.
  defp merge_head_mtime(env, root) do
    with {path, 0} <- git(env, root, ["rev-parse", "--git-path", "MERGE_HEAD"]),
         {:ok, %{mtime: mtime}} <- Environments.stat(env, git_path(root, String.trim(path))) do
      mtime
    else
      _ -> nil
    end
  end

  defp git_path(_root, "/" <> _ = absolute), do: absolute
  defp git_path(root, relative), do: Path.join(root, relative)

  defp stale_merge_reason(root, %{sha: sha, since: nil}) do
    "there is a merge already in progress in #{root}, against #{sha} — left over " <>
      "from an earlier promotion that never finished. Resolve or abort it there " <>
      "before promoting again."
  end

  defp stale_merge_reason(root, %{sha: sha, since: since}) do
    "there is a merge already in progress in #{root} since #{DateTime.to_iso8601(since)}, " <>
      "against #{sha} — left over from an earlier promotion that never finished. Resolve " <>
      "or abort it there before promoting again."
  end

  defp conflict(env, root, branch, out) do
    {status, _} = git(env, root, ["status", "--porcelain"])

    conflicted =
      status
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.match?(&1, ~r/^(UU|AA|DD|AU|UA|DU|UD)/))
      |> Enum.map(&(&1 |> String.slice(3..-1//1) |> String.trim()))

    {:error,
     %{
       reason:
         "merging #{branch} into the running copy conflicts" <>
           conflict_files(conflicted) <>
           ". The conflict is left in #{root} for you to resolve.",
       conflicts: conflicted,
       output: String.trim(out)
     }}
  end

  defp conflict_files([]), do: ""
  defp conflict_files(files), do: " in " <> Enum.join(files, ", ")

  @doc """
  Bring the application at `root` back up on whatever is now checked out.

  Through the project's own `just restart`, which is the seam. A promotion does
  not know how to start a Phoenix app, and should not learn.
  """
  @spec restart(Environments.Environment.t(), String.t()) :: result()
  def restart(env, root) do
    env
    |> Environments.exec_file_exists?(Path.join(root, "justfile"))
    |> run_restart(env, root)
  end

  defp run_restart(false, _env, root) do
    {:error,
     %{
       reason:
         "#{root} has no justfile, so there is no `just restart` to bring the " <>
           "application back up on the merged code. The merge is done; the app " <>
           "is still serving what it was."
     }}
  end

  # `stderr_to_stdout: true`, and it is the difference between a refusal an
  # agent can act on and one it cannot.
  #
  # Compilers, migrations and the shell all write their failures to stderr.
  # Without this the promotion caught a broken build correctly — non-zero exit,
  # nothing merged onward — and then reported "`just restart` failed (1):" with
  # an empty body, telling the agent its promotion failed and not one word about
  # what broke.
  defp run_restart(true, env, root) do
    case normalize(Environments.cmd(env, "just", ["restart"], cd: root, stderr_to_stdout: true)) do
      {out, 0} -> serving(env, root, out)
      {out, code} -> {:error, %{reason: "`just restart` failed (#{code}):\n#{String.trim(out)}"}}
    end
  end

  defp serving(env, root, out) do
    case git(env, root, ["rev-parse", "--short", "HEAD"]) do
      {sha, 0} -> {:ok, %{revision: String.trim(sha), output: String.trim(out)}}
      {_, _} -> {:ok, %{revision: nil, output: String.trim(out)}}
    end
  end

  # An explicit `:cd` beats the environment's own cwd, which is what lets one
  # environment drive both checkouts.
  defp git(env, root, args) do
    env
    |> Environments.cmd("git", args, cd: root, stderr_to_stdout: true)
    |> normalize()
  end

  # `{:error, reason}` is not `{output, status}`, and every caller here matches
  # the latter. Normalized to a non-zero result carrying the reason as its
  # output, so a refusal reads as a refusal rather than crashing the tool —
  # `String.trim(:error)` is what the first real invocation did instead.
  defp normalize({:error, reason}), do: {"#{inspect(reason)}", 1}
  defp normalize({output, status}) when is_binary(output), do: {output, status}
  defp normalize(other), do: {"#{inspect(other)}", 1}
end
