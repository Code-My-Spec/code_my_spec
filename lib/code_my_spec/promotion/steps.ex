defmodule CodeMySpec.Promotion.Steps do
  @moduledoc """
  The git and disk operations a promotion performs on a checkout, and nothing
  else: precheck, merge, submodule sync, version tagging, and the promotion
  queue's batch building, test-database reset and asset build.

  They run wherever the checkout is, while the gate stays on the server with
  the database. `Promotion.Runner` calls them directly for a local environment
  or sends each as a named op down the harness channel, answered by this
  module on the far side. Named ops rather than a general `cmd`:
  `Environments.Harness.cmd/4` refuses on purpose, since `analysis/run` owns
  command execution on the harness. See knowledge/promotion, "Runner and steps".
  """

  require Logger

  alias CodeMySpec.Environments

  @submodule ".code_my_spec"

  @type result :: {:ok, term()} | {:error, map()}

  @doc """
  Whether this checkout has uncommitted work, and what branch it is on.

  One operation because it is one question — "what is here, and is it safe to
  move?" — and a round trip to another machine is not free. Refused before the
  merge rather than cleaned up after.

  `--untracked-files=no` and `--ignore-submodules=all`, matching the
  `story_promoted` gate: untracked scratch files and `.code_my_spec` writes are
  not part of the build, and the two checks must agree or an agent is told to
  promote and then refused. Untracked files are reported, not refused.

  `main`, when given, is main's HEAD. A copy that does not contain it is
  refused first: a branch that is behind cannot merge the commit it would
  certify. The result carries `head`, the commit a promotion certifies and then
  merges.

  With `main`, a copy whose HEAD moves the `.code_my_spec` gitlink is also
  refused unless the new pointer is on the submodule's `origin` and descends
  from main's.
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
          clean_checkout(env, root, main)

        {dirty, 0} ->
          uncommitted(dirty)

        {out, _} ->
          unreadable(out)
      end
    end
  end

  defp clean_checkout(env, root, main) do
    with :ok <- submodule_pointer(env, root, main), do: branch(env, root)
  end

  # Not under git at all. Said plainly: a vague error led an agent to
  # `git init` a clean tree, which would certify a history nobody else has.
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

  # Guards main's gitlink against moving backwards (a stale submodule committed
  # with the work) and against unpushed pointers ("not our ref" on fresh
  # clones). Here, not in `Promotion.gate/3`, because the submodule is on this
  # disk. Only when the pointer moved, so an unchanged one costs no fetch.
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

  # Reported, not refused: an untracked file may be forgotten work, so it must
  # not be silent, but the gate ignores untracked files and promote must not
  # refuse what the gate passed.
  defp untracked(env, root) do
    case git(env, root, ["ls-files", "--others", "--exclude-standard"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.take(20)
      _ -> []
    end
  end

  @doc """
  Merge `branch` into the checkout at `root`.

  Fast-forward only: `git merge --ff-only` is both the precondition check and
  the merge — it advances the ref with nothing that could conflict, or refuses
  having touched nothing. The shared checkout is never left mid-merge.

  An unconcluded merge already in the checkout (left by a human) is concluded
  first when its conflicts are resolved, and refused when markers remain.

  The result carries `before`/`after` (HEAD on either side), `changed` (the
  paths between them, which choose reload or restart), `version` (the
  `vX.Y.Z` tag this promotion minted on the certified commit — nearest tag's
  patch plus one — or `nil` for a merge that moved nothing), `version_error`
  (the merge landed and the tag did not), and `stamp_version` (what landed
  stories are stamped with). See knowledge/promotion, "Versions".
  """
  @spec merge(Environments.Environment.t(), String.t(), String.t()) :: result()
  def merge(env, root, branch) do
    before = head(env, root)

    hold_requests(env, root)

    result =
      env
      |> unmerged(root)
      |> resume(env, root, branch, before)

    release_unless_deploying(result, env, root)
    result
  end

  # The app serving `root` reloads the merged code on its next request, and until
  # `mix ecto.migrate` has run (the `reload` recipe, a few seconds later) every
  # request is a PendingMigrationError 503 (issue 725a1d32). So the merge says a
  # landing is under way first: `CodeMySpecWeb.Plugs.HoldDuringLanding` makes
  # requests wait for the `reload` recipe (or a restart) to take it down, instead
  # of failing. The path and the format (a unix time) are that plug's; it ignores
  # a marker older than two minutes, so a landing that dies cannot hold the app.
  @landing_hold ".git/landing_hold"

  # Best effort: a hold that could not be written only means the old 503 window.
  defp hold_requests(env, root) do
    Environments.write_file(
      env,
      Path.join(root, @landing_hold),
      Integer.to_string(System.os_time(:second))
    )
  end

  defp release_requests(env, root),
    do: Environments.delete_file(env, Path.join(root, @landing_hold))

  # Only a merge that moved something is followed by a reload or a restart,
  # which is what takes the hold down. One that failed or moved nothing is
  # followed by neither.
  defp release_unless_deploying({:ok, %{changed: [_ | _]}}, _env, _root), do: :ok
  defp release_unless_deploying(_other, env, root), do: release_requests(env, root)

  # A merge already in progress (`MERGE_HEAD`, which `--ff-only` never leaves)
  # blocks `git merge`. With no conflict markers left the resolution is made
  # and only the commit is missing, so it is concluded; a marker anywhere is
  # refused, saying it is the earlier merge, not a new one.
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

        {originated, version_error} =
          case version_if_moved(env, root, before, after_sha) do
            {:ok, version} -> {version, nil}
            {:error, reason} -> {nil, reason}
            :none -> {nil, nil}
          end

        {:ok,
         %{
           output: String.trim(out),
           before: before,
           after: after_sha,
           changed: changed_between(env, root, before, after_sha),
           # The certified commit itself: a promotion tags it and commits nothing.
           head: after_sha,
           version: originated,
           # Set when the merge landed and its version tag did not. Never
           # silent: `Promotion` logs it as an error and says so in the outcome.
           version_error: version_error,
           stamp_version: originated || current_version(env, root)
         }}

      {out, _} ->
        merge_refused(root, branch, out)
    end
  end

  @doc """
  The paths that differ between `from` and `to` in the checkout at `root`:
  what certification reads to decide whether a QA pass carries forward.
  `{:ok, %{paths: paths}}`; `paths` is `nil` when they cannot be read.
  """
  def changed(env, root, from, to), do: {:ok, %{paths: changed_between(env, root, from, to)}}

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

  # `--ff-only` fails for two reasons and the refusal names which: "would be
  # overwritten by merge" is local files in the target, not divergence, and
  # telling that agent to merge main changes nothing.
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

  # "Already up to date" also exits 0. A merge that moved nothing mints no
  # version, or every repeated promote would bump the patch.
  defp version_if_moved(_env, _root, same, same), do: :none
  defp version_if_moved(env, root, _before, _after), do: tag_version(env, root)

  # The version main already carries: what a no-op merge stamps a story with.
  # Not the same question as "did this merge mint a version" — a story whose
  # code is already on main must still be stampable.
  # See knowledge/promotion, "Versions".
  defp current_version(env, root), do: tagged_version(env, root) || mix_version(env, root)

  # The version this promotion mints: an annotated tag on the certified commit
  # (main's HEAD once the ff-only merge lands), nothing committed, so a branch
  # level with main stays level. Patch bump from the nearest `vX.Y.Z` tag, or
  # from `mix.exs`'s literal when untagged. Local only. `:none` means nothing
  # to count from; a tag that failed is `{:error, reason}`, never silent.
  defp tag_version(env, root) do
    case current_version(env, root) do
      nil ->
        Logger.warning(
          "[Promotion] #{root} has no vX.Y.Z tag and no mix.exs version to count from; " <>
            "this promotion minted no version"
        )

        :none

      base ->
        with {:ok, next} <- next_patch(base) do
          create_tag(env, root, next)
        end
    end
  end

  defp create_tag(env, root, version) do
    case git(env, root, ["tag", "-a", "v#{version}", "-m", "Promote v#{version}"]) do
      {_, 0} -> {:ok, version}
      {out, _} -> {:error, "`git tag -a v#{version}` failed in #{root}: #{String.trim(out)}"}
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
        {:error, "the version to count from, #{inspect(version)}, is not X.Y.Z"}
    end
  end

  # `branch` does not contain main's HEAD. Worded as routine, not fault:
  # another promotion landing meanwhile is ordinary on a shared box.
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

  # The repository sets `submodule.recurse`, so a reset would also check out
  # the commit's `.code_my_spec` pointer and refuse when the gate's submodule
  # lacks that docs commit (an unpushed pointer wedged the queue). The gate
  # copy's submodule stays where it is.
  @leave_submodules ["-c", "submodule.recurse=false"]

  @doc """
  Build a promotion batch in the queue's gate checkout at `root`: reset it to
  `base` (main's HEAD) and merge `commits` onto it in order.

  A candidate HEAD is already an ancestor of is fast-forwarded to, so a lone
  candidate that is level with main is gated and landed as its own commit.
  Anything else is a `--no-ff` merge. A candidate that conflicts is aborted
  and reported with the conflicting files; the rest go on without it.

  `{:ok, %{head:, merged: [commit], conflicted: [%{commit:, files:}]}}`.
  """
  @spec build_batch(Environments.Environment.t(), String.t(), String.t(), [String.t()]) ::
          result()
  def build_batch(env, root, base, commits) do
    with {_, 0} <- git(env, root, ["merge", "--abort"]) |> ok_or_not_merging(),
         {_, 0} <-
           git(
             env,
             root,
             @leave_submodules ++ ["checkout", "--quiet", "--detach", "--force", base]
           ),
         {_, 0} <- git(env, root, @leave_submodules ++ ["reset", "--quiet", "--hard", base]),
         # Nobody works in the gate, so an untracked file there is a leftover
         # (one a candidate adds reads as a conflict naming no file). Ignored
         # files (`_build`, `deps`) stay.
         {_, 0} <- git(env, root, ["clean", "--quiet", "-d", "--force"]) do
      {merged, conflicted} = merge_candidates(env, root, commits)

      {:ok,
       %{
         head: head(env, root),
         merged: Enum.reverse(merged),
         conflicted: Enum.reverse(conflicted)
       }}
    else
      {out, _} ->
        {:error,
         %{reason: "could not reset the gate checkout #{root} to #{base}: #{String.trim(out)}"}}
    end
  end

  defp merge_candidates(env, root, commits) do
    Enum.reduce(commits, {[], []}, fn commit, {merged, conflicted} ->
      case add_to_batch(env, root, commit) do
        :ok -> {[commit | merged], conflicted}
        {:conflict, files} -> {merged, [%{commit: commit, files: files} | conflicted]}
      end
    end)
  end

  @doc """
  Drop the gate checkout's test databases, one per `partitions`, before its
  analyzers run a new candidate. The runs' own `ecto.create` and `ecto.migrate`
  rebuild them from the candidate's migrations.

  `ecto.migrate` only goes forward, so an ejected candidate's migrations would
  otherwise stay in these databases and fail the next candidate. Only ever for
  the gate copy — nobody works there — never for a requester's copy.

  `{:ok, %{dropped: [partition]}}`.
  """
  @spec reset_test_databases(Environments.Environment.t(), String.t(), [String.t()]) :: result()
  def reset_test_databases(env, root, partitions) do
    Enum.reduce_while(partitions, {:ok, %{dropped: []}}, fn partition, {:ok, %{dropped: done}} ->
      case drop_test_database(env, root, partition) do
        {_, 0} ->
          {:cont, {:ok, %{dropped: done ++ [partition]}}}

        {out, _} ->
          {:halt,
           {:error,
            %{
              reason:
                "could not reset the gate's test database #{partition} in #{root}: " <>
                  String.trim(out)
            }}}
      end
    end)
  end

  # A script run in the project's own VM, not a mix task of ours, so it works
  # for any project's Ecto repos. It refuses anything but a test database even
  # with `MIX_ENV` given: a scrubbed env once acted on dev, and `CMS_DRILL_DB`
  # points our test config at `code_my_spec_dev`.
  defp drop_test_database(env, root, partition) do
    env
    |> Environments.cmd("mix", ["run", "--no-start", "-e", drop_script()],
      cd: root,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}, {"MIX_TEST_PARTITION", partition}]
    )
    |> normalize()
  end

  @doc """
  Build the project's static assets (`mix assets.build` -- esbuild and
  tailwind) in the gate checkout at `root`, so a bundle the running app
  could not actually serve does not land green.

  No analyzer runs the asset pipeline, so without this a broken JS import
  lands with every analyzer green.

  Skipped, not failed, when `root` has no loadable `mix.exs` (a queue fixture
  with no Phoenix project). `MIX_ENV=test`, the build the gate's analyzers
  reuse.
  """
  @spec build_assets(Environments.Environment.t(), String.t()) :: result()
  def build_assets(env, root) do
    if loadable_mix_exs?(env, root) do
      env
      |> Environments.cmd("mix", ["assets.build"],
        cd: root,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )
      |> normalize()
      |> asset_build_result(root)
    else
      {:ok, %{skipped: true}}
    end
  end

  # Some fixtures write a bare `version: "X.Y.Z"` `mix.exs` with no
  # `defmodule`; a real project's always has one.
  defp loadable_mix_exs?(env, root) do
    case Environments.read_file(env, Path.join(root, "mix.exs")) do
      {:ok, content} -> String.contains?(content, "defmodule")
      {:error, _} -> false
    end
  end

  defp asset_build_result({_out, 0}, _root), do: {:ok, %{}}

  defp asset_build_result({out, _status}, root),
    do:
      {:error, %{reason: "the project's assets failed to build in #{root}:\n#{String.trim(out)}"}}

  @refusal """
  fn env, database ->
    cond do
      env != :test ->
        "refusing to drop a database from MIX_ENV=\#{env}; only :test drops one"

      not (is_binary(database) and String.contains?(database, "_test")) ->
        "refusing to drop \#{inspect(database)}: not named as a test database"

      true ->
        nil
    end
  end
  """

  @doc "Why a VM in `env` may not drop `database`, as script source; nil means it may."
  @spec refusal_source() :: String.t()
  def refusal_source, do: @refusal

  # Forced: a run the gate abandoned can still hold connections to it.
  defp drop_script do
    """
    refusal = #{@refusal}
    app = Mix.Project.config()[:app]

    for repo <- Application.get_env(app, :ecto_repos, []) do
      config = repo.config()
      env = String.to_atom(System.get_env("MIX_ENV") || "dev")
      if reason = refusal.(env, config[:database]), do: Mix.raise(reason)
      {:ok, _} = repo.__adapter__().ensure_all_started(config, :temporary)

      # A drop waits on a checkpoint, which ran past Postgrex's 15-second
      # default on a loaded machine (2026-10-12).
      case repo.__adapter__().storage_down(Keyword.merge(config, force_drop: true, timeout: 120_000)) do
        :ok -> IO.puts("dropped \#{config[:database]}")
        {:error, :already_down} -> IO.puts("\#{config[:database]} was already gone")
        {:error, reason} -> Mix.raise("could not drop \#{config[:database]}: \#{inspect(reason)}")
      end
    end
    """
  end

  # No merge in progress is the ordinary case, not a failure.
  defp ok_or_not_merging({_out, 0} = ok), do: ok
  defp ok_or_not_merging({_out, _}), do: {"", 0}

  defp add_to_batch(env, root, commit) do
    if ancestor?(env, root, "HEAD", commit) do
      case git(env, root, ["merge", "--quiet", "--ff-only", commit]) do
        {_, 0} -> :ok
        {_, _} -> merge_no_ff(env, root, commit)
      end
    else
      merge_no_ff(env, root, commit)
    end
  end

  defp merge_no_ff(env, root, commit) do
    message = "Promotion batch: merge #{String.slice(commit, 0, 12)}"

    case git(
           env,
           root,
           identity(env, root) ++ ["merge", "--no-ff", "--no-edit", "-m", message, commit]
         ) do
      {_, 0} ->
        :ok

      {_, _} ->
        files =
          case git(env, root, ["diff", "--name-only", "--diff-filter=U"]) do
            {out, 0} -> String.split(out, "\n", trim: true)
            _ -> []
          end

        # Not `merge --abort`: under `submodule.recurse` it fails on a
        # conflicting docs pointer and leaves the markers for the next step to
        # compile (8733d80d8, 2026-10-15). HEAD is still the pre-merge commit.
        git(env, root, @leave_submodules ++ ["reset", "--quiet", "--hard", "HEAD"])
        {:conflict, files}
    end
  end

  # A batch merge needs an author. The checkout's own identity when it has one;
  # a gate checkout minted on a machine with none still has to commit.
  defp identity(env, root) do
    case git(env, root, ["config", "user.email"]) do
      {email, 0} when email != "" -> []
      _ -> ["-c", "user.name=CodeMySpec promotion", "-c", "user.email=promotion@codemyspec.local"]
    end
  end

  defp ancestor?(env, root, maybe_ancestor, descendant) do
    match?({_, 0}, git(env, root, ["merge-base", "--is-ancestor", maybe_ancestor, descendant]))
  end

  @doc """
  Which of `commits` `base` already contains — candidates on main already, with
  nothing to gate or land. Reads only; moves nothing.

  `{:ok, %{contained: [commit]}}`, in the order given.
  """
  @spec contained(Environments.Environment.t(), String.t(), String.t(), [String.t()]) ::
          result()
  def contained(env, root, base, commits),
    do: {:ok, %{contained: Enum.filter(commits, &ancestor?(env, root, &1, base))}}

  @doc """
  The checkout's HEAD and its version — the nearest `vX.Y.Z` tag, else the
  literal in `mix.exs` — moving nothing.

  What a promote from the running copy stamps a story with: the merge path's
  rule for a no-op merge, without the merge.
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

  # Paths git considers unmerged; empty when no merge is in progress.
  #
  # "failed in submodule <name>" is git's wrapper for a submodule status check
  # failing, most often a `core.worktree` rewritten by `git submodule update`
  # in another worktree sharing the gitdir. Named, so it is not mistaken for
  # this checkout's own corruption. See knowledge/promotion, "Lessons".
  defp unmerged(env, root) do
    case git(env, root, ["diff", "--name-only", "--diff-filter=U"]) do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {out, _} -> {:error, merge_state_error(out, root)}
    end
  end

  defp merge_state_error(out, root) do
    case Regex.run(~r/failed in submodule (\S+)/, out) do
      [_, submodule] ->
        %{
          reason:
            "could not read #{root}'s merge state: its #{submodule} submodule's own " <>
              "status check failed, most likely because its gitdir's core.worktree " <>
              "points at a path that no longer exists. Something outside this " <>
              "checkout -- most likely a `git submodule update` run in a different " <>
              "worktree sharing this submodule's gitdir -- rewrote it. Fix: reset " <>
              "core.worktree in the submodule's gitdir config (`git -C " <>
              "#{root}/#{submodule} rev-parse --git-dir` finds it) to the correct " <>
              "relative path back to #{root}/#{submodule}, then retry. Raw error: " <>
              String.trim(out)
        }

      nil ->
        %{reason: "could not read #{root}'s merge state: #{String.trim(out)}"}
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

  Runs only when the merge moved the gitlink. The pinned commit is fetched by
  sha from `source`'s submodule, then from the docs remote.

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
  # answers for a plain tracked directory, which a project tracking
  # `.code_my_spec` as ordinary files would read as a moved pin.
  defp gitlink(env, root, commit) do
    case git(env, root, ["ls-tree", commit, "--", @submodule]) do
      {"160000 commit " <> rest, 0} -> rest |> String.split("\t") |> hd() |> String.trim()
      _ -> nil
    end
  end

  # The superproject check matters: in an uninitialised submodule directory
  # `git -C` would find the superproject and check the SHA out *there*.
  #
  # A dirty submodule tree refuses before the checkout: `git checkout` only
  # refuses paths that differ between the two commits and silently strands any
  # other uncommitted edit.
  defp check_out_pinned(env, sub, source, pinned) do
    with :ok <- ensure_submodule(env, sub, pinned),
         :ok <- ensure_clean(env, sub, pinned),
         :ok <- ensure_present(env, sub, source, pinned),
         {:ok, _} <- sub_git(env, sub, ["checkout", "--quiet", pinned], pinned),
         {:ok, ^pinned} <- sub_git(env, sub, ["rev-parse", "HEAD"], pinned) do
      :ok
    else
      {:ok, other} -> {:error, pinned, "checked out, but HEAD is #{other}"}
      {:error, _, _} = error -> error
    end
  end

  defp ensure_clean(env, sub, pinned) do
    case sub_git(env, sub, ["status", "--porcelain"], pinned) do
      {:ok, ""} ->
        :ok

      {:ok, dirty} ->
        {:error, pinned,
         "#{sub} has uncommitted work this checkout would strand:\n#{dirty}\n" <>
           "Commit or discard it in #{sub} before promoting, or this promote would " <>
           "silently check out over it."}

      error ->
        error
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
    if present?(env, sub, pinned), do: :ok, else: fetch_pinned(env, sub, source, pinned)
  end

  # The gate copy never moves its own submodule (`@leave_submodules`), so a
  # batch's pin is usually missing from it. `submodule_pointer/3` already
  # proved the pin is on the docs remote, so that is the fallback.
  defp fetch_pinned(env, sub, source, pinned) do
    with {:error, _, from_source} <- fetch_from(env, sub, Path.join(source, @submodule), pinned),
         {:error, _, from_origin} <- fetch_from(env, sub, "origin", pinned) do
      {:error, pinned, "#{from_source}; and from the docs remote: #{from_origin}"}
    end
  end

  defp fetch_from(env, sub, from, pinned) do
    with {:ok, _} <- sub_git(env, sub, fetch_pinned_args(from, pinned), pinned) do
      if present?(env, sub, pinned),
        do: :ok,
        else: {:error, pinned, "fetched #{pinned} from #{from}, which git did not provide"}
    end
  end

  defp present?(env, sub, pinned),
    do: match?({_, 0}, git(env, sub, ["cat-file", "-e", "#{pinned}^{commit}"]))

  # `pinned` is rarely `from`'s ref tip by the time this runs, so the fetch
  # names the exact commit. A bare SHA that is not a ref tip is refused ("not
  # our ref") unless told the server may serve one it can still reach.
  defp fetch_pinned_args(from, pinned) do
    ["-c", "uploadpack.allowReachableSHA1InWant=true", "fetch", "--quiet", from, pinned]
  end

  defp sub_git(env, sub, args, pinned) do
    case git(env, sub, args) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, pinned, "`git #{Enum.join(args, " ")}` failed: #{String.trim(out)}"}
    end
  end

  defp roll_back(env, root, merge, pinned, source, why) do
    {status, undone} = undo_merge(env, root, merge)

    {:error,
     %{
       reason:
         "the merge moved #{root}'s #{@submodule} to #{pinned}, but that commit " <>
           "could not be fetched from #{Path.join(source, @submodule)} or the docs " <>
           "remote and checked out: #{why}. #{undone} The application was not restarted. " <>
           "Make sure #{pinned} is pushed to the docs remote, then promote again.",
       # Only true when `root` is stuck on *our own* merge commit with no
       # rollback: the one shape a caller must never read as "something
       # else moved main" and gate again, which finds this commit already
       # an ancestor and lands it without ever having deployed it.
       stuck_on_main: status == :stuck,
       submodule: %{path: @submodule, wanted: pinned, detail: why}
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
        {:raced,
         "#{root} has moved to #{other || "an unreadable HEAD"} since this promote " <>
           "left it on #{made}, so the merge was NOT rolled back; #{root} still has a " <>
           "stale #{@submodule}."}
    end
  end

  # The tagged commit when a version was minted, else the fast-forwarded head.
  defp promoted_head(_env, _root, %{version: nil, after: after_sha}), do: after_sha

  defp promoted_head(env, root, %{version: version}) do
    case git(env, root, ["rev-parse", "v#{version}^{commit}"]) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp reset_to(env, root, before, merge) do
    # `@leave_submodules`: the same `submodule.recurse` hazard the gate's own
    # reset guards against -- without it, this reset tries to also check out
    # the commit it is going back to in the submodule, which is exactly the
    # checkout that just failed, so the rollback would fail for the same
    # reason the sync did.
    case git(env, root, @leave_submodules ++ ["reset", "--keep", before]) do
      {_, 0} ->
        drop_tag(env, root, Map.get(merge, :version))
        {:rolled_back, "The merge was rolled back — #{root} is back on #{before}."}

      {out, _} ->
        {:stuck,
         "Rolling the merge back also failed (#{String.trim(out)}), so #{root} " <>
           "is still on the merged commit with a stale #{@submodule}."}
    end
  end

  defp drop_tag(_env, _root, nil), do: :ok
  defp drop_tag(env, root, version), do: git(env, root, ["tag", "-d", "v#{version}"])

  # Restarting or reloading the app is not here: see `Promotion.Runner`.

  # An explicit `:cd` beats the environment's own cwd, which is what lets one
  # environment drive both checkouts.
  defp git(env, root, args, opts \\ []) do
    env
    |> Environments.cmd("git", args, [cd: root, stderr_to_stdout: true] ++ opts)
    |> normalize()
  end

  # Every caller matches `{output, status}`, so `{:error, reason}` becomes a
  # non-zero result carrying the reason, a refusal rather than a crash.
  defp normalize({:error, reason}), do: {"#{inspect(reason)}", 1}
  defp normalize({output, status}) when is_binary(output), do: {output, status}
  defp normalize(other), do: {"#{inspect(other)}", 1}
end
