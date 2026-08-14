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
  `{:drifted, booted, current}` when the checkout has moved since boot.

  `:none` covers every case that is not a clear, readable difference: never
  captured, no git, an unreadable HEAD. An uncertain answer here would be
  appended to an error message as though it were evidence, and a wrong "restart
  your harness" costs more than a missing one.
  """
  @spec drift() :: {:drifted, String.t(), String.t()} | :none
  def drift do
    case :persistent_term.get(@key, nil) do
      {root, booted} when is_binary(booted) ->
        compare(booted, head(root))

      _ ->
        :none
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
  defp head(root) do
    with true <- is_binary(root) and File.dir?(root),
         git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <-
           System.cmd(git, ["rev-parse", "--short", "HEAD"], cd: root, stderr_to_stdout: true) do
      String.trim(output)
    else
      _ -> nil
    end
  end
end
