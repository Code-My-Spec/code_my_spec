defmodule CodeMySpec.BootVersion do
  @moduledoc """
  The commit a running process's code was loaded from, so a stale one can say so.

  A long-running process runs the code it booted with. When the checkout it runs from moves —
  a merge, a rebase, a branch switch — its code and the server's can disagree
  about the channel contract, and every stop afterwards fails with something
  that names neither the merge nor the harness. Reported in `7e8fd1c6`: 137
  commits merged mid-session, and from that moment every stop got
  `{:error, %{"reason" => "unmatched topic"}}` until the harness was restarted.

  Only ever consulted on a failure path. Drift is the normal state of an active
  session — the checkout moves with every commit while the harness keeps
  running, and it is usually fine, because most commits do not touch the
  harness. Reporting it proactively would fire constantly and be ignored;
  reporting it beside an error the reader is already holding turns a guess about
  version skew into a fact they can act on.

  The *process's own* checkout, not any working copy it was asked about. One
  process can serve several projects, and the question here is whether this
  process's code is stale — which is about where it was started, and nowhere
  else.

  Two callers, for two different questions. `CmsHarness.Supervisor` asks whether
  the checkout moved under it, and reports drift beside an error the reader is
  already holding. `CodeMySpec.Application` asks only *which* commit is
  answering, because a server behind `main` serves messages about correctness
  that read as the fix not working rather than as the build being old
  (`5e59a29d`).
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  @key {__MODULE__, :boot}

  @doc """
  The commit recorded at boot, or nil.

  Distinct from `drift/0`: this answers "which code is this?" rather than "has
  the checkout moved since?". A response naming it lets a reader tell a fix that
  is not deployed from one that does not work, which are otherwise the same
  observation.
  """
  @spec booted() :: String.t() | nil
  def booted do
    case :persistent_term.get(@key, nil) do
      {_root, sha} when is_binary(sha) -> sha
      _ -> nil
    end
  end

  @doc """
  The checkout this process booted from, or nil.

  The other half of the pair `capture/1` stores. `booted/0` answers "which
  commit"; this answers "which checkout" — needed by a caller asking not
  "is my code current" but "is the checkout I am about to restart the one
  running me", which is a question about the root, not the sha.
  """
  @spec booted_root() :: String.t() | nil
  def booted_root do
    case :persistent_term.get(@key, nil) do
      {root, _sha} when is_binary(root) -> root
      _ -> nil
    end
  end

  @doc """
  What to call this build, in one string.

  The commit where there is one, the release version otherwise. A packaged
  server has no checkout of its own, and `capture/1` must not be called there:
  it defaults to `File.cwd!()`, which for a released binary is wherever the user
  invoked it — usually *a* project, whose HEAD has nothing to do with the code
  running. A confidently wrong sha is worse than no sha, and this is the answer
  that is right for both shapes.

  `just publish` moves the version in lockstep with the release, so it
  identifies a packaged build as well as a sha identifies a checkout.
  """
  @spec describe() :: String.t()
  def describe do
    case booted() do
      nil -> "v#{Application.spec(:code_my_spec, :vsn)}"
      sha -> sha
    end
  end

  @doc """
  Record where this harness booted from. Called once, at start.

  Silent when there is no git — a sprite runs from an unpacked release with no
  checkout at all, and a harness that refused to boot over a missing `git`
  would be a far worse failure than the one this reports.

  Recording is cheap and unconditional: one `git rev-parse` at boot. What was
  expensive was asking again on every stop hook, and that caller is gone.
  """
  @spec capture(String.t() | nil) :: :ok
  def capture(root \\ nil) do
    root = root || File.cwd!()
    :persistent_term.put(@key, {root, head(root)})
  end

  @doc """
  `{:drifted, booted, current}` when what is running is behind what the project
  has.

  Two ways that happens, and only one of them used to be caught.

  The checkout moves under a running process — someone commits or rebases in the
  tree that launched it. `head/1` sees that immediately.

  Or the checkout does not move at all, and the code still does. This project is
  worked through git worktrees, and the harness and server both run from the
  main checkout whatever directory started them (`just refresh-harness` says so
  outright). An agent in a worktree commits, pushes to `origin/main`, and the
  main checkout's HEAD is exactly where it was — so the old comparison found
  booted == HEAD and answered `:none` while five commits sat unrun, two of them
  touching `@contract_paths` (`9c474a9d`). The available readings for the agent
  were "my fix is wrong" and "my fix is not running", and nothing distinguished
  them.

  So the upstream ref is consulted too. That is a **local** read: worktrees share
  an object store and refs, so a push from any of them updates the
  remote-tracking ref this checkout sees, with no network and no fetch.

  `:none` still covers every case that is not a clear, readable difference —
  never captured, no git, an unreadable HEAD, no upstream configured. An
  uncertain answer here would be appended to an error message as though it were
  evidence, and a wrong "restart your harness" costs more than a missing one.
  """
  @spec drift() :: {:drifted, String.t(), String.t()} | :none
  def drift do
    case :persistent_term.get(@key, nil) do
      {root, booted} when is_binary(booted) ->
        {target, _kind} = assess(root)
        compare(booted, target)

      _ ->
        :none
    end
  end

  @doc """
  Why the running code is stale, which decides the remedy.

  `:checkout_moved` — the tree that launched this process has moved. Restarting
  it picks the new code up.

  `:behind_upstream` — the checkout has not moved and is itself behind its
  upstream, which is what happens when an agent in a worktree pushes. **A
  restart alone changes nothing here**: it relaunches the same commit. The
  checkout has to be pulled first. That distinction is the whole point of
  separating this from `drift/0` — a message saying "restart" to someone in this
  state sends them to do the one thing that cannot work, and I spent part of an
  evening in exactly that position (`9c474a9d`).

  `:none` whenever `drift/0` is `:none`.
  """
  @spec stale_kind() :: :checkout_moved | :behind_upstream | :none
  def stale_kind do
    case :persistent_term.get(@key, nil) do
      {root, booted} when is_binary(booted) ->
        {target, kind} = assess(root)
        kind_when_drifted(compare(booted, target), kind)

      _ ->
        :none
    end
  end

  defp kind_when_drifted(:none, _kind), do: :none
  defp kind_when_drifted({:drifted, _booted, _current}, kind), do: kind

  # What this process ought to be running, and why it differs. One source of
  # truth, so `drift/0` and `stale_kind/0` cannot disagree about which case
  # this is.
  #
  # HEAD first because a moved checkout is the more urgent of the two — the code
  # on disk already disagrees with the process — and because it is the case that
  # needs no remote-tracking ref to exist.
  defp assess(root) do
    head = head(root)

    case behind_upstream(root, head) do
      nil -> {head, :checkout_moved}
      upstream -> {upstream, :behind_upstream}
    end
  end

  # The upstream commit when this checkout is strictly behind it, `nil`
  # otherwise. `nil` for a checkout that is ahead, level, on an unrelated
  # branch, or has no upstream at all — none of those mean the running code is
  # stale, and saying "drifted" for them would train readers to ignore it.
  defp behind_upstream(root, head) when is_binary(head) do
    with upstream when is_binary(upstream) <- upstream_ref(root),
         true <- upstream != head,
         true <- ancestor?(root, head, upstream) do
      upstream
    else
      _ -> nil
    end
  end

  defp behind_upstream(_root, _head), do: nil

  # `@{upstream}` first, `origin/<branch>` when that is not configured.
  #
  # The fallback is not belt-and-braces, it is the case that matters. The main
  # checkout on this machine — the one both long-running processes serve from —
  # has a `[branch "main"]` section carrying `vscode-merge-base` and no `remote`
  # or `merge` key, so `@{upstream}` does not resolve there and the first
  # version of this returned `nil` in the exact configuration it was written
  # for. Shipped blind, and only caught by reading `/health` afterwards and
  # asking why a checkout that was demonstrably behind reported no drift.
  #
  # That is the same failure this function exists to fix, one layer down: an
  # instrument that cannot answer in the situation where the answer is needed.
  # A branch with a tracking ref set is the tidy case; a long-lived checkout
  # someone has pulled in for years is the ordinary one.
  #
  # Convention rather than configuration, so it stays `nil` when there is no
  # such ref — a guess about which remote is worse than no answer.
  defp upstream_ref(root) do
    rev_parse(root, "@{upstream}") || origin_ref(root)
  end

  defp origin_ref(root) do
    case current_branch(root) do
      nil -> nil
      "HEAD" -> nil
      branch -> rev_parse(root, "origin/" <> branch)
    end
  end

  # Detached HEAD answers the literal string "HEAD", which names no branch and
  # so has no `origin/` counterpart — refused above rather than turned into
  # `origin/HEAD`, which resolves to the default branch and would compare
  # against something the checkout is not on.
  defp current_branch(root) do
    case git(root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp ancestor?(root, maybe_ancestor, descendant) do
    case git(root, ["merge-base", "--is-ancestor", maybe_ancestor, descendant]) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp rev_parse(root, ref) do
    case git(root, ["rev-parse", "--short", ref]) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp compare(booted, booted), do: :none
  defp compare(_booted, nil), do: :none
  defp compare(booted, current), do: {:drifted, booted, current}

  # Whether the drifted range touched the code that decides whether a harness
  # and a server can talk to each other.
  #
  # `drift/0` alone says the checkout moved, which is the normal state of an
  # active session and true after almost every commit. Whether it *matters* is a
  # different question, and the answer was left to the reader: the message said
  # "if that range touched the harness or the channel contract, restart it", and
  # the reader who acted on it ran
  #
  #     git diff --stat 0dd3fc43..8a18a296 -- lib/cms_harness lib/code_my_spec_web/channels
  #
  # by hand, then called it diagnosis to confirmation in one command. This is
  # that command, so the message can state a fact instead of a condition.
  #
  # `:unknown` rather than a guess when the range cannot be read — a rebase can
  # leave the booted commit unreachable, and a confident "nothing changed" would
  # send a genuinely stale harness back to look at its network.
  @contract_paths ["lib/cms_harness", "lib/code_my_spec_web/channels"]

  @spec contract_changed?(String.t(), String.t()) :: boolean() | :unknown
  def contract_changed?(booted, current), do: changed?(booted, current, @contract_paths)

  @doc """
  Whether the drifted range touched the code that decides analysis results.

  A different question from `contract_changed?/2`, and the one an analyzer
  result has to answer about itself. A harness runs the analyzer it booted
  with, so a fix to `StaticAnalysis` or the runners is not in force until the
  harness is rebuilt — and until then it decides stops with the old rules while
  the fix sits in `main`.

  Measured (`d9f0846c`): `be9a46f8` landed mid-afternoon and the harness's
  compiled `StaticAnalysis.Pipeline.beam` was from the previous day, eleven
  commits behind, for an entire session. Three stop-hook loops were spent on
  findings that were already fixed.

  What made it expensive is that it is invisible from inside the loop. "credo —
  stale, a rerun is in flight" is true, and useless, because the rerun runs the
  old code; and it renders identically to the defect it was masking. The
  correct diagnosis needed a `.beam` timestamp, which is not a thing anyone
  thinks to check while being told a rerun is coming.
  """
  @analyzer_paths [
    "lib/code_my_spec/static_analysis",
    "lib/code_my_spec/analysis",
    "lib/cms_harness/project"
  ]

  @spec analyzer_changed?(String.t(), String.t()) :: boolean() | :unknown
  def analyzer_changed?(booted, current), do: changed?(booted, current, @analyzer_paths)

  @doc """
  How the analyzer should describe its own build alongside a result.

  `nil` when there is nothing to say — no drift, or the range cannot be read.
  A string when the build deciding this result predates a change to analyzer
  code, which is the case the reader needs and cannot otherwise see.
  """
  @spec analyzer_staleness() :: String.t() | nil
  def analyzer_staleness do
    with {:drifted, booted, current} <- drift(),
         true <- analyzer_changed?(booted, current) do
      staleness_message(stale_kind(), booted, current)
    else
      _ -> nil
    end
  end

  # `just refresh` rebuilds from the checkout, so it is the right instruction
  # only when the checkout holds the newer code. When the checkout is itself
  # behind, refreshing rebuilds the same commit and the result looks unchanged
  # for a reason nothing states.
  defp staleness_message(:behind_upstream, booted, current) do
    "this result came from a build at #{booted}; the checkout is behind its upstream " <>
      "at #{current}, and that range changed analyzer code — pull in that checkout, " <>
      "then rebuild the harness (`just refresh`) before acting on it"
  end

  defp staleness_message(_kind, booted, current) do
    "this result came from a build at #{booted}; the checkout is now at #{current}, " <>
      "and that range changed analyzer code — rebuild the harness " <>
      "(`just refresh`) before acting on it"
  end

  # `config_changed?/2` sat here, asking the same question of `config/` so the
  # stop hook could warn that this process was wedged. Its only caller made a
  # `git rev-parse` fork on every stop for an answer that is almost always "no",
  # and killed twenty-one spex on the way: the spex cassettes patch
  # `System.cmd/3` process-globally, so a `git` call inside a request dies on a
  # missing recording and takes the criterion with it.
  #
  # `contract_changed?/2` survives because its caller is the failure path — a
  # hook that has already gone wrong, where one fork buys the difference between
  # "reconnect" and "your harness is older than the server".

  defp changed?(booted, current, paths) do
    case :persistent_term.get(@key, nil) do
      {root, _} -> changed_paths(root, booted, current, paths)
      _ -> :unknown
    end
  end

  defp changed_paths(root, booted, current, paths) do
    with true <- is_binary(root) and File.dir?(root),
         git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <-
           System.cmd(git, ["diff", "--name-only", "#{booted}..#{current}", "--" | paths],
             cd: root,
             stderr_to_stdout: true
           ) do
      String.trim(output) != ""
    else
      _ -> :unknown
    end
  end

  # `find_executable/1` before `cmd/3` and a `File.dir?/1` before the `:cd`,
  # because both of those raise rather than returning a tuple and this must not
  # be able to take down the path it is decorating.
  defp head(root), do: rev_parse(root, "HEAD")

  # One place that knows how to run git against a checkout, so `head/1`,
  # `rev_parse/2` and `ancestor?/3` cannot drift in how they handle a missing
  # binary or a directory that is not there.
  defp git(root, args) do
    with true <- is_binary(root) and File.dir?(root),
         git when is_binary(git) <- System.find_executable("git") do
      System.cmd(git, args, cd: root, stderr_to_stdout: true)
    else
      _ -> :error
    end
  end
end
