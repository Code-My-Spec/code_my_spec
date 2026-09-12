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

  Three named operations rather than one `promote`, because `precheck` reads
  the *promoting* copy's root while `merge` and `restart` act on the
  *running* one — two different disks a single op cannot address — and
  because `restart` is dispatched separately from the other two on purpose
  (54aa534c, phase two): `promote/1` answers as soon as `merge` lands, and
  the restart it starts afterward is never awaited, so it cannot be a step
  inside the same call that reports the merge.

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

  `--ignore-submodules=all`, for the same reason and matching the same gate:
  `.code_my_spec` is a submodule a QA agent writes into continuously for the
  one-to-two hours it works — a brief drafted, a screenshot captured,
  `prompt.md` regenerated on every task — none of which touches anything this
  checkout's own merge would carry. Without the flag here too, the two checks
  would disagree again the moment one of them dropped it: `code_on_running_copy`
  waving a copy through while `promote` refused the same submodule dirt it had
  just ignored (c97bb142).
  """
  @spec precheck(Environments.Environment.t(), String.t()) :: result()
  def precheck(env, root) do
    case git(env, root, [
           "status",
           "--porcelain",
           "--untracked-files=no",
           "--ignore-submodules=all"
         ]) do
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

  Fast-forward only. A promotion no longer attempts a three-way merge at
  all: `branch` must already contain everything `root`'s current HEAD has,
  and `git merge --ff-only` is both the precondition check and the merge in
  one command — it either advances the ref instantly with nothing that could
  conflict, or refuses instantly having touched nothing, with no third
  outcome (John: "we should guarantee with our preconditions that the merge
  will be clean").

  This replaced a three-way merge that aborted on conflict (`git merge
  --abort`, `bed1d974`) rather than leaving one in place. That was already
  right about *never leaving the shared checkout wedged* — a promotion lands
  cleanly or does not touch the tree at all — but a real conflict was still
  reachable, and reaching it meant a promotion had already spent the time to
  find out. Requiring the ancestor relationship up front removes the
  question rather than answering it faster: a branch missing commits from
  main cannot conflict here any more than it can succeed here, because
  neither is attempted.

  `git merge` also refuses outright while `MERGE_HEAD` exists from an
  earlier, unconcluded merge — the shape a three-way merge could leave and a
  fast-forward cannot create going forward. Concluding a resolved one before
  starting this one, below, stays as a defensive path for a checkout that
  still carries one from before this change, or from a human merging by hand
  outside a promotion.

  A successful merge's result also carries `before`/`after` — the checkout's
  HEAD on either side of it. `Promotion` needs that range to ask
  `BootVersion.contract_changed?/2` whether the merge touched the code that
  decides whether a harness and a server can talk to each other (376e3356);
  reading it here, where the git access to `root` already is, is cheaper than
  a fourth round trip to ask again.
  """
  @spec merge(Environments.Environment.t(), String.t(), String.t()) :: result()
  def merge(env, root, branch) do
    before = head(env, root)

    env
    |> unmerged(root)
    |> resume(env, root, branch, before)
  end

  # A merge already in progress, finished before this one starts.
  #
  # `git merge` refuses outright while `MERGE_HEAD` exists — "you have not
  # concluded your merge" — which is a state only a three-way merge could ever
  # leave. `--ff-only` cannot: it either advances the ref or refuses having
  # touched nothing, so nothing here is reachable from a promotion that ran
  # under this version. Kept for a checkout still carrying one from before
  # this change, or from a human merging by hand outside a promotion —
  # measured cost of a stale one going unhandled: eight hours resolving a
  # conflict that was four hours old and already resolved, because the old
  # code read `git status` fresh and reported it as new.
  #
  # Concluding somebody's resolution is not the same as guessing at it. If no
  # unmerged path still carries conflict markers then the decision has been
  # made and only the commit is missing, which is a step and not a judgement. A
  # marker anywhere means the question is still open, and that is refused —
  # saying what the state actually is, which is the sentence that was missing.
  defp resume({:ok, []}, env, root, branch, before), do: do_merge(env, root, branch, before)

  defp resume({:ok, paths}, env, root, branch, before) do
    case Enum.filter(paths, &marked?(env, root, &1)) do
      [] -> conclude(env, root, branch, paths, before)
      unresolved -> still_open(root, unresolved)
    end
  end

  defp resume({:error, _} = error, _env, _root, _branch, _before), do: error

  defp conclude(env, root, branch, paths, before) do
    with {_, 0} <- git(env, root, ["add", "--"] ++ paths),
         {_, 0} <- git(env, root, ["commit", "--no-edit"]) do
      do_merge(env, root, branch, before)
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

  defp do_merge(env, root, branch, before) do
    case git(env, root, ["merge", "--ff-only", branch]) do
      {out, 0} -> {:ok, %{output: String.trim(out), before: before, after: head(env, root)}}
      {out, _} -> not_fast_forward(root, branch, out)
    end
  end

  # `--ff-only` refuses before touching the tree — no three-way merge is
  # attempted, so there is nothing to abort and no conflicted file to name.
  # The one thing it can mean is the one thing it says: `branch` does not
  # already contain everything `root`'s current HEAD has.
  #
  # Said as routine, not as fault. This is the most-read string in the
  # system — someone else's promotion landing on main while this one was
  # being worked is ordinary on a shared box, not a mistake, and it will fire
  # often (phx-new-generator-0f: three times in two hours on this machine).
  # The wording says so directly rather than reading like an error the agent
  # caused.
  defp not_fast_forward(root, branch, out) do
    {:error,
     %{
       reason:
         "#{branch} is behind main, most likely because another promotion " <>
           "landed while this one was in progress — normal on a shared " <>
           "checkout, not a mistake. Nothing was merged — #{root} is " <>
           "unchanged. In the copy you are promoting from: " <>
           "`git merge --ff-only main` (or a real merge if that refuses), " <>
           "then promote again.",
       output: String.trim(out)
     }}
  end

  # `nil` rather than raising when HEAD cannot be read — `before` is read
  # before anything is known to be safe, and a checkout with no commits yet
  # (or a transient git failure) must not take the merge down over a value
  # that only ever feeds an optimization, never a correctness check.
  defp head(env, root) do
    case git(env, root, ["rev-parse", "HEAD"]) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
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

  @doc """
  Bring the application at `root` back up on whatever is now checked out.

  Through the project's own `just restart`, which is the seam. A promotion does
  not know how to start a Phoenix app, and should not learn.

  `refresh_harness?` (default `true`) is whether `restart` should also rebuild
  the harness at its tail. `Promotion` passes `false` only when it has already
  established, from the merge that just landed, that the range could not have
  touched the channel contract (376e3356) — skipping is a cost-saving
  optimization for that one caller, not a new default.

  Signaled through an environment variable, not a `just` CLI argument. This
  function calls `root`'s *own* `just restart` — a promoted project's own
  recipe, or the synthetic one criterion 3175's spex writes to prove the
  restart always runs — and neither is guaranteed to declare a parameter for
  this. An env var a recipe never reads is invisible to it; an extra
  positional argument to a recipe that does not declare it is not silently
  ignored — `just` reads the next token as the name of a *second* recipe to
  also run and fails with "justfile does not contain recipe <value>"
  (confirmed empirically before this shipped, against exactly the zero-
  parameter shape criterion 3175's fixture uses).
  """
  @spec restart(Environments.Environment.t(), String.t(), boolean()) :: result()
  def restart(env, root, refresh_harness? \\ true) do
    env
    |> Environments.exec_file_exists?(Path.join(root, "justfile"))
    |> run_restart(env, root, refresh_harness?)
  end

  defp run_restart(false, _env, root, _refresh_harness?) do
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
  defp run_restart(true, env, root, refresh_harness?) do
    opts = [cd: root, stderr_to_stdout: true, env: skip_harness_env(refresh_harness?)]

    case normalize(Environments.cmd(env, "just", ["restart"], opts)) do
      {out, 0} -> serving(env, root, out)
      {out, code} -> {:error, %{reason: "`just restart` failed (#{code}):\n#{String.trim(out)}"}}
    end
  end

  defp skip_harness_env(true), do: []
  defp skip_harness_env(false), do: [{"CMS_SKIP_HARNESS_REFRESH", "true"}]

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
