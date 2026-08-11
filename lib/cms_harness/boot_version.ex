defmodule CmsHarness.BootVersion do
  @moduledoc """
  The commit this harness's code was loaded from, so a stale one can say so.

  A harness runs the code it booted with. When the checkout it runs from moves —
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

  The harness's *own* checkout, not the working copy a hook named. One harness
  can serve several projects, and the question here is whether this process's
  code is stale — which is about where it was started, and nowhere else.
  """

  @key {__MODULE__, :boot}

  @doc """
  Record where this harness booted from. Called once, at start.

  Silent when there is no git — a sprite runs from an unpacked release with no
  checkout at all, and a harness that refused to boot over a missing `git`
  would be a far worse failure than the one this reports.
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
