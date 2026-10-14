defmodule CodeMySpec.BootVersion do
  @moduledoc """
  The commit a running process's code was loaded from, so a stale one can say so.

  A long-running process runs the code it booted with. When its checkout moves,
  its code and the server's can disagree (about the channel contract, or
  analyzer rules) with errors that name neither.

  Drift is reported only beside an error the reader already holds
  (`CmsHarness.HookDecision`, `CmsHarness.Web.HealthController`): drift is the
  normal state of an active session, and proactive reports would be ignored.
  `describe/0` names which build is answering (boot log, `/health`,
  `register_session`), so an undeployed fix is not mistaken for a broken one.

  Always the *process's own* checkout, captured at boot
  (`CmsHarness.Supervisor`, `CodeMySpecWeb.Application`), never a working copy
  it was asked about.

  Also owns `restart_paths/0` / `needs_restart/1`, which decide whether a
  promote reloads or restarts.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  @key {__MODULE__, :boot}

  @doc """
  The commit recorded at boot, or nil.

  Answers "which code is this?", not "has the checkout moved since?" (`drift/0`).
  """
  @spec booted() :: String.t() | nil
  def booted do
    case :persistent_term.get(@key, nil) do
      {_root, sha} when is_binary(sha) -> sha
      _ -> nil
    end
  end

  @doc """
  What to call this build, in one string.

  The commit where there is one, the release version otherwise. A packaged
  server has no checkout of its own and must not `capture/1`: its cwd is
  whatever project the user invoked it in, and a wrong sha is worse than none.
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

  Silent when there is no git (a sprite runs from an unpacked release): a
  harness must never refuse to boot over this. One `git rev-parse`, at boot only.
  """
  @spec capture(String.t() | nil) :: :ok
  def capture(root \\ nil) do
    root = root || File.cwd!()
    :persistent_term.put(@key, {root, head(root)})
  end

  @doc """
  `{:drifted, booted, current}` when what is running is behind what the project
  has.

  Two ways: the checkout that launched it moved (HEAD differs), or the checkout
  is itself strictly behind its upstream — a push from a worktree moves the
  shared remote-tracking ref without moving this checkout. The upstream read
  is local (worktrees share refs), no fetch.

  `:none` for anything that is not a clear, readable difference — never
  captured, no git, unreadable HEAD, no upstream. A wrong "restart your
  harness" costs more than a missing one.
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
  upstream (an agent in a worktree pushed). **A restart alone changes nothing
  here**: it relaunches the same commit. The checkout has to be pulled first.

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

  # What this process ought to be running, and why it differs: one source, so
  # `drift/0` and `stale_kind/0` cannot disagree.
  defp assess(root) do
    head = head(root)

    case behind_upstream(root, head) do
      nil -> {head, :checkout_moved}
      upstream -> {upstream, :behind_upstream}
    end
  end

  # The upstream commit when this checkout is strictly behind it, `nil`
  # otherwise (ahead, level, unrelated, no upstream: none mean stale code).
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

  # `@{upstream}` first, `origin/<branch>` when that is not configured — the
  # common case for a long-lived checkout with no tracking keys. `nil` when
  # neither exists: a guess about which remote is worse than no answer.
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

  # Detached HEAD answers "HEAD", refused above rather than turned into
  # `origin/HEAD`, which is the default branch, not the checkout's.
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

  # Whether the drifted range touched the harness/server channel contract, so
  # the message states a fact instead of a condition. `:unknown` when the range
  # cannot be read (a rebase can make the booted commit unreachable).
  @contract_paths ["lib/cms_harness", "lib/code_my_spec_web/channels"]

  @spec contract_changed?(String.t(), String.t()) :: boolean() | :unknown
  def contract_changed?(booted, current), do: changed?(booted, current, @contract_paths)

  @doc """
  Whether the drifted range touched the code that decides analysis results.

  A harness runs the analyzer it booted with, so a fix to `StaticAnalysis` or
  the runners is not in force until the harness is rebuilt, and a rerun only
  repeats the old verdict. Invisible from inside the loop, so an analyzer
  result carries it (`analyzer_staleness/0`).
  """
  @analyzer_paths [
    "lib/code_my_spec/static_analysis",
    "lib/code_my_spec/analysis",
    "lib/cms_harness/project"
  ]

  @spec analyzer_changed?(String.t(), String.t()) :: boolean() | :unknown
  def analyzer_changed?(booted, current), do: changed?(booted, current, @analyzer_paths)

  @doc """
  The paths a running app cannot take by hot reload, so a promote touching
  any of them restarts the app rather than reloading it.

  Deps and the lockfile, compile-time config, supervision trees, releases,
  asset deps and the toolchain pin. Phoenix's own reloader refuses the first
  three outright ("You must restart your server after changing configuration
  files or your dependencies"); the rest load nothing new until a boot. MCP
  servers register their tools at boot, so a changed registration does too.

  Globs: `**` spans directories, `*` stays inside one.
  """
  @restart_paths ~w(
    mix.exs
    mix.lock
    config/**
    lib/**/application.ex
    rel/**
    assets/package*.json
    .tool-versions
    lib/code_my_spec/mcp_servers/*_server.ex
    lib/code_my_spec/mcp_servers/scriptable_tools.ex
  )

  @spec restart_paths() :: [String.t()]
  def restart_paths, do: @restart_paths

  @doc "The entries of `changed` (repo-relative paths) that need a restart, not a reload."
  @spec needs_restart([String.t()]) :: [String.t()]
  def needs_restart(changed) when is_list(changed) do
    patterns = Enum.map(@restart_paths, &glob_regex/1)
    Enum.filter(changed, fn path -> Enum.any?(patterns, &Regex.match?(&1, path)) end)
  end

  defp glob_regex(glob) do
    body =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.compile!("^" <> body <> "$")
  end

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

  # `just refresh` rebuilds from the checkout, so a checkout that is itself
  # behind must be pulled first.
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

  # Git is forked only on failure paths, never per stop: spex cassettes patch
  # `System.cmd/3` process-globally. See knowledge/promotion, "Lessons".

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

  defp head(root), do: rev_parse(root, "HEAD")

  # `find_executable/1` and `File.dir?/1` first: `System.cmd/3` raises on
  # either, and this must not take down the error path it decorates.
  defp git(root, args) do
    with true <- is_binary(root) and File.dir?(root),
         git when is_binary(git) <- System.find_executable("git") do
      System.cmd(git, args, cd: root, stderr_to_stdout: true)
    else
      _ -> :error
    end
  end
end
