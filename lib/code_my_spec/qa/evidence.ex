defmodule CodeMySpec.Qa.Evidence do
  @moduledoc """
  Whether a story's QA evidence is committed, asked before the claim is recorded.

  ## The gap this closes

  `submit_qa_result` records a pass on the server and closes `qa_complete`. The
  brief and screenshots backing it are written to `.code_my_spec/qa/<story>/` —
  and `.code_my_spec` is a **git submodule** (`code_my_spec_docs`) that nothing
  in the QA flow commits. So the claim propagates and the evidence stays in one
  working copy.

  Measured (`0a1435c7`): four briefs sat uncommitted in one worktree, one of them
  for a story that had shipped the night before with QA recorded complete and all
  six requirements satisfied. The evidence substantiating that existed on exactly
  one machine.

  Nothing says so at any point. A submodule sits in detached HEAD by design, so
  it accepts writes normally; the superproject reports at most a one-line dirty
  pointer; and this project suppresses even that with `--ignore-submodules=all`,
  for good reasons that have nothing to do with QA. The one signal that would
  surface it is off everywhere.

  ## A refusal, not a commit

  The issue's first suggestion was for `submit_qa_result` to commit and push the
  submodule itself. This refuses instead, which is the same shape
  `Mix.Tasks.Cms.CheckTestMigrations` settled on and for the same reason: a tool
  call that quietly pushes to a remote is an outward-facing action nobody asked
  for, and this codebase has already paid for background processes taking
  irreversible actions on shared state — `CmsHarness.TestDatabase` lost its
  create and migrate after they ran against the shared dev database three times
  in one day.

  Refusing gets the same outcome by a route the operator can see: the claim
  cannot be recorded until the evidence is saved, so they land together.

  ## Cannot-tell is not clean

  Three answers, deliberately. A harness environment refuses `cmd` outright
  (`analysis/run` owns running commands there), so on a light harness this
  cannot be checked at all — and reporting that as "committed" would be the
  same absent-information-as-good-news shape the whole issue is about. It
  returns `:unknown` and the caller says so.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Paths

  @submodule ".code_my_spec"

  @type verdict :: :ok | {:uncommitted, [String.t()]} | {:unknown, term()}

  @doc """
  Whether story `story_id`'s QA evidence is committed in the docs submodule.

    * `:ok` — nothing untracked or modified under `qa/<story_id>/`.
    * `{:uncommitted, paths}` — the paths git reports as dirty, submodule-relative.
    * `{:unknown, reason}` — this machine could not answer. Never treated as `:ok`.
  """
  @spec committed?(Environments.Environment.t() | nil, integer() | String.t()) :: verdict()
  def committed?(nil, _story_id), do: {:unknown, :no_working_copy}

  def committed?(env, story_id) do
    case initialized?(env) do
      :ok -> status(env, story_id)
      {:unknown, reason} -> {:unknown, reason}
    end
  rescue
    # `Environments.cmd` raises on an environment with no working directory
    # rather than returning a tuple. That is a legitimate state here — a server
    # holding no checkout — and it is `:unknown`, not a crash in the QA tool.
    # On `committed?/2` rather than on either helper, so it covers the
    # `rev-parse` as well as the `status`.
    error in ArgumentError -> {:unknown, Exception.message(error)}
  end

  # An empty `git status` is only evidence when the directory is its own
  # repository.
  #
  # `.code_my_spec` is a submodule, and a submodule is initialized in the main
  # checkout and **not** in a worktree, where the path is an ordinary directory
  # holding whatever was written into it. The superproject records it as a
  # gitlink, so git ignores its contents entirely — `status -- qa/<story>` run
  # in there resolves to the *outer* repository and prints nothing whether the
  # brief is committed, uncommitted, or absent.
  #
  # Nothing distinguishes that from clean. `ab52cdfa`: briefs and screenshots
  # sat untracked in a worktree and were never preserved, reported as committed
  # every time, on top of the four this module already exists for (`0a1435c7`).
  #
  # `rev-parse --show-toplevel` is the one-command tell. In an initialized
  # submodule it answers the submodule's own path; in a worktree stub it answers
  # the worktree root, which is the outer repo saying "these files are not
  # mine".
  defp initialized?(env) do
    path = submodule_path(env)

    case Environments.cmd(env, "git", ["rev-parse", "--show-toplevel"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> same_repo(String.trim(output), path)
      {:error, reason} -> {:unknown, reason}
      {_output, status} when is_integer(status) -> {:unknown, :submodule_not_a_repository}
    end
  end

  # Compared by basename rather than by full path, because the two are spelled
  # differently for reasons that have nothing to do with this. git resolves
  # symlinks and the caller does not, so on macOS a checkout under `/var/…`
  # comes back as `/private/var/…` and an initialized submodule reads as an
  # uninitialized one. `Path.expand/1` does not close that — it normalises `..`
  # and `~`, not symlinks.
  #
  # The basename is the whole signal anyway: an initialized submodule's toplevel
  # is the submodule directory, and an uninitialized one's is the superproject
  # root, which is some checkout's name and not `.code_my_spec`.
  defp same_repo(toplevel, path) do
    if Path.basename(toplevel) == Path.basename(path),
      do: :ok,
      else: {:unknown, :submodule_not_initialized}
  end

  defp status(env, story_id) do
    # `--porcelain` because the human-readable output is localised and
    # reformatted between git versions; this is parsed, so it takes the format
    # that promises not to change.
    #
    # Scoped to the one story's directory. A submodule with unrelated dirt in it
    # is the normal state of this repo — `hex_docs/` churns constantly — and
    # refusing a QA pass over somebody else's uncommitted file would be a gate
    # that fires for reasons the reader cannot act on.
    # `-uall` because plain `--porcelain` collapses a wholly-untracked directory
    # to a single `qa/874/` entry. That is the common case here — a QA pass
    # writes a brief and a screenshots folder into a directory git has never
    # seen — and a refusal that names a directory instead of the files in it
    # tells the reader less than the `git status` they would run next.
    case Environments.cmd(
           env,
           "git",
           ["status", "--porcelain", "-uall", "--", story_dir(story_id)],
           cd: submodule_path(env),
           stderr_to_stdout: true
         ) do
      {output, 0} -> verdict(output)
      # Before the catch-all below, which is also a two-tuple and would swallow
      # it — `{:error, :not_supported_on_harness}` is what a harness environment
      # answers, and reading that as "git exited non-zero" would report a
      # transport limit as a git failure.
      {:error, reason} -> {:unknown, reason}
      {output, status} when is_integer(status) -> {:unknown, String.trim(output)}
    end
  end

  @doc """
  The refusal text, naming the paths and the exact commands.

  Written out rather than left to the caller because the reader is an agent that
  has just finished a QA pass and is being told no. What it needs is the two
  commands, in the submodule, in order.
  """
  @spec refusal(integer() | String.t(), [String.t()]) :: String.t()
  def refusal(story_id, paths) do
    listed = paths |> Enum.take(10) |> Enum.map_join("\n", &"  #{&1}")

    more =
      case length(paths) - 10 do
        n when n > 0 -> "\n  … and #{n} more"
        _ -> ""
      end

    """
    Submission rejected: story #{story_id}'s QA evidence is not committed.

    Uncommitted under #{@submodule}/#{story_dir(story_id)}:
    #{listed}#{more}

    `.code_my_spec` is a git submodule. A pass recorded now would propagate to \
    the server and close `qa_complete` while the brief and screenshots backing \
    it stayed in this working copy — and these worktrees are disposable by \
    design. That is not an audit-grade event.

    Commit and push the evidence, then resubmit:

      git -C #{@submodule} add #{story_dir(story_id)}
      git -C #{@submodule} commit -m "QA evidence for story #{story_id}"
      git -C #{@submodule} push

    Nothing else about the pass changes; this refuses the claim, not the result.
    """
  end

  @doc """
  The note appended when this machine could not check.

  Said out loud rather than passed silently: "could not verify" and "verified
  clean" are the same colour otherwise, which is the defect this module exists
  for one level up.

  `:not_supported_on_harness` gets its own wording. For every other reason,
  "could not tell" is an anomaly worth investigating. For this one it is not —
  a harness-connected QA session is the expected way these run (issue
  `e79458db`), and every single pass on one hits this, because the server
  never holds the harness's own checkout to look at
  (`CodeMySpec.Environments.Harness.cmd/4` refuses `cmd` on purpose: it
  already has a route, `analysis/run`, and a second one would drift from it).
  Generic "not verified" language read as failure to at least one QA agent,
  which retried a pass that had already recorded — the wording here says
  plainly that this is structural, not a retry signal, while still asking the
  one party that *can* check (the agent, on its own disk) to do so.
  """
  @spec unknown_note(term()) :: String.t()
  def unknown_note(:not_supported_on_harness) do
    "\nQA evidence not independently verified — this pass ran on a harness, and " <>
      "the server has no filesystem access there to check. That's expected, not " <>
      "an error: the attempt above is recorded regardless. Before you finish, " <>
      "confirm it yourself:\n\n" <>
      "  git -C .code_my_spec rev-parse --show-toplevel   # must end in /.code_my_spec\n" <>
      "  git -C .code_my_spec status --porcelain -uall -- qa/<story_id>   # must print nothing\n\n" <>
      "Both, in that order. In a git worktree `.code_my_spec` is usually not " <>
      "checked out as a submodule, and then the second command reports the " <>
      "*outer* repository — which ignores those files, so it prints nothing " <>
      "whether your evidence is committed, uncommitted or absent. The first " <>
      "command is what tells the two apart."
  end

  # Named, because this one has a remedy and the generic wording sends the
  # reader to the wrong place — it says the server has no working copy when the
  # working copy is right there with a hollow `.code_my_spec` in it.
  def unknown_note(:submodule_not_initialized) do
    "\nQA evidence could not be verified: `#{@submodule}` is not checked out as " <>
      "a submodule here, so git reports the outer repository and would call any " <>
      "state clean.\n\n" <>
      "This is the ordinary state of a git worktree, and it means two things " <>
      "beyond this check. Anything you read under `#{@submodule}/` is whatever " <>
      "happened to be written there rather than what is tracked — a QA plan that " <>
      "looks missing is not missing, it is in the main checkout — and anything " <>
      "you write there is preserved by nothing.\n\n" <>
      "Initialize it before trusting either direction:\n\n" <>
      "  git submodule update --init #{@submodule}\n\n" <>
      "If that refuses with \"destination path already exists and is not an " <>
      "empty directory\", the stub already holds loose files; move them aside " <>
      "first rather than deleting, in case a brief is among them."
  end

  def unknown_note(reason) do
    "\nQA evidence not verified (#{inspect(reason)}) — this server has no working " <>
      "copy to check. Make sure `.code_my_spec` is committed and pushed where the " <>
      "brief was written, or the claim outlives its evidence."
  end

  defp verdict(output) do
    case parse_paths(output) do
      [] -> :ok
      paths -> {:uncommitted, paths}
    end
  end

  # Porcelain v1 is two status columns, a space, then the path: `?? qa/x`,
  # ` M qa/x`, `A  qa/x`.
  #
  # **Parsed by splitting on whitespace, never by column position.**
  #
  # `Environments.cmd/4` used to trim its output, so ` M qa/874/brief.md`
  # arrived as `M qa/874/brief.md` — one character shorter, on the first line
  # only, and only for the statuses whose first column is blank, which is most
  # of the interesting ones. That is fixed at the source now (`2f6695dd`), but
  # this stays whitespace-based: it is correct either way, and a parser that
  # depends on a column surviving three layers of transport is one restart of
  # that argument away from being wrong again.
  #
  # Two attempts failed on that and both failed *silently*; the tests caught
  # both. `String.slice(line, 3..-1//1)` returned `"a/874/brief.md"` — a path
  # quietly one character short still looks like a path, so the refusal would
  # have named a file that does not exist. Matching `<<_::binary-size(2), " ",
  # path::binary>>` matched nothing at all, so every dirty file read as clean,
  # which is the one direction this module must never fail in.
  #
  # Renames carry ` -> ` and the destination is the one that matters.
  defp parse_paths(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&capture_path/1)
  end

  defp capture_path(line) do
    case line |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [_status, path] -> [path |> String.split(" -> ") |> List.last() |> String.trim()]
      _ -> []
    end
  end

  defp story_dir(story_id), do: Path.join(Path.basename(Paths.qa_dir()), to_string(story_id))

  defp submodule_path(env), do: Path.join(env.cwd, @submodule)
end
