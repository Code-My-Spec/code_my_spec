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

  Leaving it there has a cost this did not pay, though: `git merge` will not run
  at all while `MERGE_HEAD` exists, so the *next* promotion failed on the old
  merge and described it as a new one. Concluding a resolved merge before
  starting this one is what closes that, and it is a step rather than a
  judgement — the resolution is already on disk, only the commit is missing. A
  path that still carries markers is refused, and the refusal says a merge is in
  progress rather than naming a file.
  """
  @spec merge(Environments.Environment.t(), String.t(), String.t()) :: result()
  def merge(env, root, branch) do
    env
    |> unmerged(root)
    |> resume(env, root, branch)
  end

  # A merge already in progress, finished before this one starts.
  #
  # `git merge` refuses outright while `MERGE_HEAD` exists — "you have not
  # concluded your merge" — and that refusal used to fall into `conflict/4`,
  # which reads `git status` and reports whatever is unmerged as though this
  # merge had just produced it. So a half-merge left by one promotion made every
  # later promotion report the same file, and the message named the file rather
  # than the state. Eight hours went into resolving a conflict that was four
  # hours old and already resolved.
  #
  # Concluding somebody's resolution is not the same as guessing at it. If no
  # unmerged path still carries conflict markers then the decision has been
  # made and only the commit is missing, which is a step and not a judgement. A
  # marker anywhere means the question is still open, and that is refused —
  # saying what the state actually is, which is the sentence that was missing.
  defp resume({:ok, []}, env, root, branch), do: do_merge(env, root, branch)

  defp resume({:ok, paths}, env, root, branch) do
    case Enum.filter(paths, &marked?(env, root, &1)) do
      [] -> conclude(env, root, branch, paths)
      unresolved -> still_open(root, unresolved)
    end
  end

  defp resume({:error, _} = error, _env, _root, _branch), do: error

  defp conclude(env, root, branch, paths) do
    with {_, 0} <- git(env, root, ["add", "--"] ++ paths),
         {_, 0} <- git(env, root, ["commit", "--no-edit"]) do
      do_merge(env, root, branch)
    else
      {out, _} ->
        {:error,
         %{
           reason:
             "a merge was already in progress in #{root} and its conflicts were " <>
               "resolved, but concluding it failed: #{String.trim(out)}",
           conflicts: paths
         }}
    end
  end

  defp still_open(root, paths) do
    {:error,
     %{
       reason:
         "#{root} is still in a merge from an earlier promotion, and " <>
           Enum.join(paths, ", ") <>
           " still carries conflict markers. Nothing new was merged. Resolve " <>
           "those, then promote again — this is the earlier merge, not a new one.",
       conflicts: paths
     }}
  end

  defp do_merge(env, root, branch) do
    case git(env, root, ["merge", "--no-edit", branch]) do
      {out, 0} -> {:ok, %{output: String.trim(out)}}
      {out, _} -> conflict(env, root, branch, out)
    end
  end

  # Paths git considers unmerged. Empty when no merge is in progress, which is
  # the ordinary case and the one that costs a single command.
  defp unmerged(env, root) do
    case git(env, root, ["diff", "--name-only", "--diff-filter=U"]) do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {out, _} -> {:error, %{reason: "could not read #{root}'s merge state: #{String.trim(out)}"}}
    end
  end

  # Whether the file on disk still has a conflict in it. Read through the
  # environment rather than `File.read/1`, because the checkout is on whichever
  # machine the harness is.
  defp marked?(env, root, path) do
    case Environments.read_file(env, Path.join(root, path)) do
      {:ok, content} -> String.contains?(content, "<<<<<<<")
      _ -> true
    end
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
