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

  @submodule ".code_my_spec"

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
  inconsistency. `story_promoted` passed a checkout whose only dirt was
  untracked, told the agent its remedy was `promote`, and `promote` then refused
  that same checkout — measured on Broken Oaths, where an untracked
  `code_my_spec_test_repos` directory belonging to nobody on the team would have
  blocked every promotion from that copy forever.

  `--ignore-submodules=all`, for the same reason and matching the same gate:
  `.code_my_spec` is a submodule a QA agent writes into continuously for the
  one-to-two hours it works — a brief drafted, a screenshot captured,
  `prompt.md` regenerated on every task — none of which touches anything this
  checkout's own merge would carry. Without the flag here too, the two checks
  would disagree again the moment one of them dropped it: `story_promoted`
  waving a copy through while `promote` refused the same submodule dirt it had
  just ignored (c97bb142).

  `main`, when given, is main's HEAD. A copy that does not contain it is
  refused first: analysing a branch that is behind certifies a commit that
  cannot merge (28d72f8a). The result carries `head`, the commit a promotion
  certifies and then merges.

  With `main`, a copy whose HEAD moves the `.code_my_spec` gitlink is also
  refused unless the new pointer is on the submodule's `origin` and descends
  from main's (7e7539ec).
  """
  @spec precheck(Environments.Environment.t(), String.t(), String.t() | nil) :: result()
  def precheck(env, root, main \\ nil) do
    with :ok <- contains_main(env, root, main) do
      case git(env, root, [
             "status",
             "--porcelain",
             "--untracked-files=no",
             "--ignore-submodules=all"
           ]) do
        {"", 0} ->
          with :ok <- submodule_pointer(env, root, main), do: branch(env, root)

        {dirty, 0} ->
          uncommitted(dirty)

        {out, _} ->
          unreadable(out)
      end
    end
  end

  # Not under git at all (67e6b5cb). "could not read this checkout's state"
  # led an agent to `git init && git commit` to get a clean tree — which would
  # certify a history nobody else has. Said plainly, with what to do instead.
  defp unreadable(out) do
    if out =~ "not a git repository" do
      {:error,
       %{
         reason:
           "this checkout is not a git repository, so there is no commit to certify. " <>
             "Do not create one — a new repository here is a history nobody else has. " <>
             "Report it (`create_issue`) and stop.",
         not_a_repository: true
       }}
    else
      {:error, %{reason: "could not read this checkout's state: #{String.trim(out)}"}}
    end
  end

  defp contains_main(_env, _root, nil), do: :ok

  defp contains_main(env, root, main) do
    case git(env, root, ["merge-base", "--is-ancestor", main, "HEAD"]) do
      {_, 0} ->
        :ok

      {_, 1} ->
        {:error,
         %{
           reason:
             "this copy is behind main (#{main}), most likely because another " <>
               "promotion landed while you worked — normal on a shared checkout, " <>
               "not a mistake. Nothing was merged or analysed: a branch that is " <>
               "behind cannot merge the commit it would certify. Merge main in — " <>
               "`git merge --ff-only main` (or a real merge if that refuses) — then " <>
               "promote again.",
           behind_main: main
         }}

      {out, _} ->
        {:error, %{reason: "could not tell whether this copy contains main: #{String.trim(out)}"}}
    end
  end

  # 7e7539ec: one promote moved main's gitlink back to an older docs commit (a
  # stale submodule checkout committed with the work); another pinned a commit
  # never pushed, so fresh clones failed with "not our ref". Checked here, not
  # in `Promotion.gate/3`: the gate runs on the server with no checkout, and
  # this runs where the promoting copy's submodule is on disk. Only when the
  # pointer moved, so an unchanged one costs no fetch.
  defp submodule_pointer(_env, _root, nil), do: :ok

  defp submodule_pointer(env, root, main) do
    case {gitlink(env, root, main), gitlink(env, root, "HEAD")} do
      {_, nil} -> :ok
      {same, same} -> :ok
      {target, pointer} -> pointer_published(env, Path.join(root, @submodule), target, pointer)
    end
  end

  defp pointer_published(env, sub, target, pointer) do
    with :ok <- initialised(env, sub, target, pointer),
         {:ok, url} <- fetch_origin(env, sub, target, pointer),
         :ok <- on_remote(env, sub, url, target, pointer) do
      descends(env, sub, url, target, pointer)
    end
  end

  # In an uninitialised submodule directory `git -C` finds the superproject.
  defp initialised(env, sub, target, pointer) do
    case git(env, sub, ["rev-parse", "--show-superproject-working-tree"]) do
      {out, 0} when out != "" ->
        :ok

      {out, _} ->
        pointer_refused(
          target,
          pointer,
          "this copy moves #{@submodule} from #{moved(target, pointer)}, but #{sub} is not " <>
            "an initialised submodule checkout#{detail(out)}, so the new pointer cannot be " <>
            "checked against the docs remote. Nothing was merged. Run " <>
            "`git submodule update --init #{@submodule}`, then promote again."
        )
    end
  end

  # An explicit refspec and `--prune`, so the remote-tracking refs are exactly
  # the remote's branches whatever the clone's config. A failed fetch refuses:
  # a pointer that cannot be shown to be pushed is not assumed to be.
  @fetch ["fetch", "--quiet", "--prune", "origin", "+refs/heads/*:refs/remotes/origin/*"]

  defp fetch_origin(env, sub, target, pointer) do
    with {:url, {url, 0}} <- {:url, git(env, sub, ["remote", "get-url", "origin"])},
         url = String.trim(url),
         {:fetch, {_, 0}} <-
           {:fetch, git(env, sub, @fetch, env: [{"GIT_TERMINAL_PROMPT", "0"}])} do
      {:ok, url}
    else
      {:url, {out, _}} ->
        pointer_refused(
          target,
          pointer,
          "this copy moves #{@submodule} from #{moved(target, pointer)}, but #{sub} has no " <>
            "`origin` remote to check #{pointer} against#{detail(out)}. Nothing was merged. " <>
            "Add the docs remote as `origin` in #{@submodule}, then promote again."
        )

      {:fetch, {out, _}} ->
        pointer_refused(
          target,
          pointer,
          "this copy moves #{@submodule} from #{moved(target, pointer)}, and checking that " <>
            "#{pointer} is on the docs remote failed: could not fetch #{@submodule}'s " <>
            "origin#{detail(out)}. Nothing was merged: an unverified pointer is refused, " <>
            "not assumed pushed. Make the remote reachable, then promote again."
        )
    end
  end

  defp on_remote(env, sub, url, target, pointer) do
    case git(env, sub, [
           "for-each-ref",
           "--contains",
           pointer,
           "--format=%(refname)",
           "refs/remotes/origin/"
         ]) do
      {refs, 0} when refs != "" ->
        :ok

      _ ->
        pointer_refused(
          target,
          pointer,
          "your branch moves #{@submodule} from #{moved(target, pointer)}, but #{pointer} is " <>
            "not on any branch of the docs remote (#{url}), so no other checkout can fetch " <>
            "it (\"not our ref\"). Nothing was merged. Push #{pointer} to the docs remote " <>
            "first (in #{@submodule}: `git push origin #{pointer}:main`, or onto any branch), " <>
            "then promote again."
        )
    end
  end

  # A branch that adds the gitlink has no pointer of main's to descend from.
  defp descends(_env, _sub, _url, nil, _pointer), do: :ok

  defp descends(env, sub, url, target, pointer) do
    case git(env, sub, ["cat-file", "-e", "#{target}^{commit}"]) do
      {_, 0} ->
        env
        |> git(sub, ["merge-base", "--is-ancestor", target, pointer])
        |> ancestry(env, sub, target, pointer)

      _ ->
        pointer_refused(
          target,
          pointer,
          "your branch moves #{@submodule} from #{target} to #{pointer}, but main's pointer " <>
            "#{target} is not on the docs remote (#{url}) or in #{sub}, so whether yours " <>
            "descends from it cannot be checked. Nothing was merged. Push #{target} to the " <>
            "docs remote from the checkout that has it, then promote again."
        )
    end
  end

  defp ancestry({_, 0}, _env, _sub, _target, _pointer), do: :ok

  defp ancestry({_, 1}, env, sub, target, pointer) do
    case git(env, sub, ["merge-base", "--is-ancestor", pointer, target]) do
      {_, 0} ->
        pointer_refused(
          target,
          pointer,
          "your branch moves #{@submodule} from #{target} back to #{pointer}, an older docs " <>
            "commit, most likely a stale submodule checkout committed with your work. " <>
            "Nothing was merged. Set it to #{target} or a descendant with " <>
            "`git update-index --cacheinfo 160000,#{target},#{@submodule}` and commit, then " <>
            "promote again."
        )

      _ ->
        pointer_refused(
          target,
          pointer,
          "your branch moves #{@submodule} from #{target} to #{pointer}, which does not " <>
            "descend from it: the docs histories have diverged, and merging would drop " <>
            "main's docs commits. Nothing was merged. In #{@submodule}, merge #{target} into " <>
            "your docs work and push it, point at the result with " <>
            "`git update-index --cacheinfo 160000,<sha>,#{@submodule}` and commit, then " <>
            "promote again."
        )
    end
  end

  defp ancestry({out, _}, _env, sub, target, pointer) do
    pointer_refused(
      target,
      pointer,
      "your branch moves #{@submodule} from #{target} to #{pointer}, but whether it " <>
        "descends from main's pointer could not be checked in #{sub}#{detail(out)}. " <>
        "Nothing was merged."
    )
  end

  defp moved(nil, pointer), do: "nothing to #{pointer}"
  defp moved(target, pointer), do: "#{target} to #{pointer}"

  defp detail(out) do
    case String.trim(out) do
      "" -> ""
      text -> " (#{text})"
    end
  end

  defp pointer_refused(target, pointer, reason),
    do: {:error, %{reason: reason, submodule: %{main: target, branch: pointer}}}

  # Porcelain v1: two status columns and a space, then the path.
  defp uncommitted(dirty) do
    files =
      dirty
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> String.slice(3..-1//1) |> String.trim()))

    {:error,
     %{
       reason:
         "this copy has uncommitted work in #{Enum.join(files, ", ")}. " <>
           "Commit it, then promote.",
       dirty: String.trim_trailing(dirty),
       dirty_files: files
     }}
  end

  defp branch(env, root) do
    case git(env, root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {branch, 0} ->
        {:ok,
         %{branch: String.trim(branch), head: head(env, root), untracked: untracked(env, root)}}

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
  HEAD on either side of it, which `Promotion` logs — and `changed`, the paths
  between them, which `Promotion` reads to choose a reload or a restart.

  It also carries `version` — the version this promotion originated by tagging
  the certified commit `vX.Y.Z` (the nearest tag's patch, plus one), or `nil`
  for a merge that moved nothing. `Promotion` uses it to stamp every story on the promoting copy with a
  permanent record that its code reached main, in place of asking the
  promoting copy's live git state the same question again later and getting a
  different answer once that copy has moved on to something else.
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
      {out, 0} ->
        after_sha = head(env, root)
        originated = version_if_moved(env, root, before, after_sha)

        {:ok,
         %{
           output: String.trim(out),
           before: before,
           after: after_sha,
           changed: changed_between(env, root, before, after_sha),
           # The certified commit itself: a promotion tags it and commits nothing.
           head: after_sha,
           version: originated,
           stamp_version: originated || current_version(env, root)
         }}

      {out, _} ->
        merge_refused(root, branch, out)
    end
  end

  # What the merge brought in, which `Promotion` reads to choose a reload or a
  # restart. `nil` when it cannot be read, which restarts.
  defp changed_between(_env, _root, same, same), do: []
  defp changed_between(_env, _root, nil, _after_sha), do: nil

  defp changed_between(env, root, before, after_sha) do
    case git(env, root, ["diff", "--name-only", "#{before}..#{after_sha}"]) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> nil
    end
  end

  # `git merge --ff-only` fails for more than one reason, and the refusal used
  # to assert the same one every time.
  #
  # A dirty tree is the other common one: git aborts with "would be overwritten
  # by merge" and names the files, *while printing the fast-forward it was about
  # to make*. Reporting that as "behind main" sends the reader to
  # `git merge --ff-only main`, which is a no-op for it — so the remedy confirms
  # the diagnosis by changing nothing, and the next attempt fails identically.
  #
  # Measured on the math project 2026-09-22: one untracked `mix.lock` in the
  # target. The coding agent verified `git merge-base --is-ancestor main sum`
  # twice, ran the suggested merge twice, and filed a framework issue saying
  # promote "looks like it is comparing against a stale or wrong reference
  # rather than the actual git ancestry". It was reading the only evidence it
  # had, and the evidence was wrong.
  #
  # `out` was already being carried on the error; now it decides what the error
  # says.
  @doc false
  def merge_refusal(root, branch, out), do: merge_refused(root, branch, out)

  defp merge_refused(root, branch, out) do
    case dirty_tree_refusal(out) do
      nil -> not_fast_forward(root, branch, out)
      files -> would_be_overwritten(root, files, out)
    end
  end

  defp dirty_tree_refusal(out) do
    case Regex.run(~r/would be overwritten by merge:\s*\n(.+?)\n\s*(?:Please|Aborting)/s, out) do
      [_, block] ->
        block |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      nil ->
        nil
    end
  end

  defp would_be_overwritten(root, files, out) do
    {:error,
     %{
       reason:
         "the merge is a clean fast-forward, but #{root} has local files it " <>
           "would overwrite: #{Enum.join(files, ", ")}. Nothing was merged. " <>
           "This is not a divergence — the branch is ahead, and git says so in " <>
           "the output below. Remove or commit those files in that checkout, " <>
           "then promote again. Merging main into the copy you are promoting " <>
           "from will not help.",
       output: String.trim(out)
     }}
  end

  # `git merge --ff-only` exits 0 for "Already up to date." too — the branch
  # named nothing this checkout did not already have, and `before == after`
  # says so directly. A promotion that landed nothing does not get to
  # originate a version for it: a version is supposed to answer "which
  # promotion put this on main," and one with no commits behind it answers
  # that question about nothing. Confirmed empirically before this guard
  # existed: a repeated or racing `promote` call minted a fresh tag and
  # patch bump on every call, with no corresponding change to anything.
  defp version_if_moved(_env, _root, same, same), do: nil
  defp version_if_moved(env, root, _before, _after), do: tag_version(env, root)

  # The version a story carried onto main should be stamped with, which is not
  # the same question as the version this promotion originated.
  #
  # `version_if_moved/4` above answers "did this merge mint a version," and nil
  # is the right answer for an "Already up to date" merge — a promotion that
  # landed no commits does not get to mint a patch bump, and the guard above
  # exists because repeated promotes used to do exactly that. `Promotion` was
  # then reusing that same nil to decide whether to stamp any story, and those
  # two questions come apart precisely where it matters.
  #
  # A story whose code is already on main is the story a no-op merge is looking
  # at. Refusing to stamp it means nothing ever can: the only thing that stamps
  # is a merge that moves the sha, and for that story there is nothing left to
  # move. The gate it feeds never becomes satisfiable again by any sequence of
  # actions an agent can take.
  #
  # Measured on Broken Oaths 2026-09-22. Story 937's code reached main on the
  # 23:30 promote that minted 0.3.3; its `specs_ready` latch — which is what
  # `mark_ready_stories_promoted/2` selects on — was written at 23:38:07, eight
  # minutes after that stamp set was taken. The three promotes that followed
  # were all no-ops (05d5453 -> 05d5453, "version none"), so the story sat at
  # 23 of 24 requirements permanently while the graph went on offering its
  # promote to every role. Three agents declined it nineteen times between them
  # before the damper capped them.
  #
  # So a no-op stamps with the version main already carries, which is the
  # honest answer to "which promotion put this on main" — for 937 that is
  # 0.3.3, the merge that did carry it. Nothing is minted and nothing is
  # committed: `mix.exs` is not rewritten, no tag moves, `version` stays nil,
  # and the log line still reads "version none".
  #
  # e1174640 closed the exposure this used to widen: a promote now stamps only
  # the story it names (`Stories.mark_story_promoted/4`), not every specs-ready
  # story in the project.
  defp current_version(env, root), do: tagged_version(env, root) || mix_version(env, root)

  # The version this promotion originates, or nil.
  #
  # An annotated tag on the commit the gate certified, which is main's HEAD the
  # instant the ff-only merge lands. Nothing is committed: main is byte-identical
  # to the certified commit, so a branch already level with it stays level and
  # the next promotion does not have to merge main again (John, 2026-10-04).
  #
  # Patch only, from the nearest `vX.Y.Z` tag. A checkout with no tag yet starts
  # from the literal version in its `mix.exs`, which is what every promotion
  # before this bumped. nil says "this promotion minted no version", not "it
  # failed": `Promotion` then stamps nothing, as before. Local only — a tag
  # leaves the machine when someone pushes it.
  defp tag_version(env, root) do
    with base when is_binary(base) <- current_version(env, root),
         {:ok, next} <- next_patch(base),
         {_, 0} <- git(env, root, ["tag", "-a", "v#{next}", "-m", "Promote v#{next}"]) do
      next
    else
      _ -> nil
    end
  end

  # The nearest `vX.Y.Z` tag reachable from HEAD, without the `v`.
  defp tagged_version(env, root) do
    case git(env, root, ["describe", "--tags", "--abbrev=0", "--match", "v[0-9]*.[0-9]*.[0-9]*"]) do
      {"v" <> version, 0} -> String.trim(version)
      _ -> nil
    end
  end

  # A literal `version: "X.Y.Z"` in HEAD's `mix.exs`, for a project not yet tagged.
  defp mix_version(env, root) do
    with {contents, 0} <- git(env, root, ["show", "HEAD:mix.exs"]),
         [_, version] <- Regex.run(~r/version:\s*"(\d+\.\d+\.\d+)"/, contents) do
      version
    else
      _ -> nil
    end
  end

  defp next_patch(version) do
    case Version.parse(version) do
      {:ok, %Version{major: major, minor: minor, patch: patch}} ->
        {:ok, "#{major}.#{minor}.#{patch + 1}"}

      :error ->
        :error
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
  @doc """
  The checkout's HEAD and the version its `mix.exs` carries, moving nothing.

  What a promote from the running copy stamps a story with: the merge path's
  rule for a no-op merge, without the merge (e1174640).
  """
  @spec current(Environments.Environment.t(), String.t()) :: result()
  def current(env, root),
    do: {:ok, %{head: head(env, root), version: current_version(env, root)}}

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
  Check out, in `root`'s own `.code_my_spec`, the commit the merge just pinned.

  Runs only when the merge moved the gitlink. The pinned commit usually exists
  only in the promoting copy's submodule, so it is fetched from `source`'s
  `HEAD` — a bare SHA is refused ("not our ref") unless it is a ref tip.

  On failure the merge is rolled back (`reset --keep` to `before`, and the tag
  it minted deleted), so the refusal leaves main as it found it and a retry
  runs the whole promotion again rather than a no-op merge onto stale docs.
  """
  @spec sync_submodule(Environments.Environment.t(), String.t(), String.t(), map()) :: result()
  def sync_submodule(env, root, source, %{before: before, after: after_sha} = merge) do
    with {:moved, pinned} <- gitlink_moved(env, root, before, after_sha),
         :ok <- check_out_pinned(env, Path.join(root, @submodule), source, pinned) do
      {:ok, %{submodule: pinned}}
    else
      :unchanged -> {:ok, %{submodule: nil}}
      {:error, pinned, why} -> roll_back(env, root, merge, pinned, source, why)
    end
  end

  defp gitlink_moved(_env, _root, same, same), do: :unchanged
  defp gitlink_moved(_env, _root, nil, _after), do: :unchanged

  defp gitlink_moved(env, root, before, after_sha) do
    case {gitlink(env, root, before), gitlink(env, root, after_sha)} do
      {_, nil} -> :unchanged
      {same, same} -> :unchanged
      {_, pinned} -> {:moved, pinned}
    end
  end

  # A gitlink is a tree entry of mode 160000. `rev-parse <commit>:<path>` also
  # answers for a plain tracked directory, with its tree SHA — which then read as
  # a moved pin, and a project that tracks `.code_my_spec` as ordinary files
  # (metric_flow, 8b27cc4c) had every merge refused and rolled back.
  defp gitlink(env, root, commit) do
    case git(env, root, ["ls-tree", commit, "--", @submodule]) do
      {"160000 commit " <> rest, 0} -> rest |> String.split("\t") |> hd() |> String.trim()
      _ -> nil
    end
  end

  # The superproject check matters: in an uninitialised submodule directory
  # `git -C` would find the superproject and check the SHA out *there*.
  defp check_out_pinned(env, sub, source, pinned) do
    with :ok <- ensure_submodule(env, sub, pinned),
         :ok <- ensure_present(env, sub, source, pinned),
         {:ok, _} <- sub_git(env, sub, ["checkout", "--quiet", pinned], pinned),
         {:ok, ^pinned} <- sub_git(env, sub, ["rev-parse", "HEAD"], pinned) do
      :ok
    else
      {:ok, other} -> {:error, pinned, "checked out, but HEAD is #{other}"}
      {:error, _, _} = error -> error
    end
  end

  defp ensure_submodule(env, sub, pinned) do
    case sub_git(env, sub, ["rev-parse", "--show-superproject-working-tree"], pinned) do
      {:ok, ""} -> {:error, pinned, "#{sub} is not an initialised submodule checkout"}
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp ensure_present(env, sub, source, pinned) do
    case git(env, sub, ["cat-file", "-e", "#{pinned}^{commit}"]) do
      {_, 0} ->
        :ok

      _ ->
        with {:ok, _} <-
               sub_git(
                 env,
                 sub,
                 ["fetch", "--quiet", Path.join(source, @submodule), "HEAD"],
                 pinned
               ),
             {_, 0} <- git(env, sub, ["cat-file", "-e", "#{pinned}^{commit}"]) do
          :ok
        else
          {:error, _, _} = error -> error
          {_, _} -> {:error, pinned, "fetched #{source}'s HEAD, which does not contain it"}
        end
    end
  end

  defp sub_git(env, sub, args, pinned) do
    case git(env, sub, args) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, pinned, "`git #{Enum.join(args, " ")}` failed: #{String.trim(out)}"}
    end
  end

  defp roll_back(env, root, merge, pinned, source, why) do
    undone = undo_merge(env, root, merge)

    {:error,
     %{
       reason:
         "the merge moved #{root}'s #{@submodule} to #{pinned}, but that commit " <>
           "could not be fetched from #{Path.join(source, @submodule)} and checked " <>
           "out: #{why}. #{undone} The application was not restarted. Make sure " <>
           "#{pinned} is committed in the promoting copy's #{@submodule}, then promote again."
     }}
  end

  # Only this promote's own commit is undone: if anything has moved HEAD since,
  # resetting would discard someone else's work, which is worse than stale docs.
  defp undo_merge(env, root, %{before: before} = merge) do
    made = promoted_head(env, root, merge)

    case head(env, root) do
      ^made when is_binary(made) ->
        reset_to(env, root, before, merge)

      other ->
        "#{root} has moved to #{other || "an unreadable HEAD"} since this promote " <>
          "left it on #{made}, so the merge was NOT rolled back; #{root} still has a " <>
          "stale #{@submodule}."
    end
  end

  # The version commit when one was minted, else the fast-forwarded head.
  defp promoted_head(_env, _root, %{version: nil, after: after_sha}), do: after_sha

  defp promoted_head(env, root, %{version: version}) do
    case git(env, root, ["rev-parse", "v#{version}^{commit}"]) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp reset_to(env, root, before, merge) do
    case git(env, root, ["reset", "--keep", before]) do
      {_, 0} ->
        drop_tag(env, root, Map.get(merge, :version))
        "The merge was rolled back — #{root} is back on #{before}."

      {out, _} ->
        "Rolling the merge back also failed (#{String.trim(out)}), so #{root} " <>
          "is still on the merged commit with a stale #{@submodule}."
    end
  end

  defp drop_tag(_env, _root, nil), do: :ok
  defp drop_tag(env, root, version), do: git(env, root, ["tag", "-d", "v#{version}"])

  # Story 1108, criterion 4663: bringing the application back up after a
  # promotion no longer runs through here. `Promotion.Runner.restart/3` calls
  # `WorkingCopies.AppTransport.restart_app/2` directly — the same per-copy
  # app mechanism every working copy already uses, reached through
  # `Analysis.HarnessRegistry` rather than through `Environments`. What used
  # to be `just restart`'s own harness-refresh tail call on this repo (this
  # repo's own `refresh-harness`, keeping server and harness on one commit)
  # is now an optional `after-promote` recipe `CmsHarness.AppInstance` runs
  # on the far side after the app is confirmed serving — declared once, in
  # this project's own justfile, rather than as a branch here that every
  # other project's promotion would also have to answer for.

  # An explicit `:cd` beats the environment's own cwd, which is what lets one
  # environment drive both checkouts.
  defp git(env, root, args, opts \\ []) do
    env
    |> Environments.cmd("git", args, [cd: root, stderr_to_stdout: true] ++ opts)
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
