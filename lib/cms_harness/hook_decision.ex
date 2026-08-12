defmodule CmsHarness.HookDecision do
  @moduledoc """
  What a hook answers when the harness could not ask.

  One module, because the property at stake is a property of the *wording* as
  much as of the control flow: **"I asked and there is nothing to do" and "I
  could not ask" must never render the same.** Scattering these strings across
  controllers is how they converge.

  Two rules, both learned the hard way:

  * **Name the harness, not the server.** An hour went into a failure that read
    "MCP server is down" while the server was perfectly healthy. Whoever reads
    one of these strings has to know which process to go and look at.
  * **The stop hook refuses.** Its job is to decide whether the agent may stop.
    With no connection it cannot decide, and allowing the stop is the silent
    green light this whole design exists to prevent.

  ## The one concession to livelock

  A block that repeats forever is its own outage: the agent can neither stop
  nor do anything useful, and on an unattended run it burns the budget. Claude
  Code sends `stop_hook_active: true` on a stop that a hook has already
  blocked, so the second one through is allowed — loudly, with a
  `systemMessage` saying the turn was never verified.

  Allowed-and-labelled is still distinguishable from verified-and-clean, which
  is the property that matters. Allowed-and-silent would not be.
  """

  alias CmsHarness.Project.ChannelClient

  @deciding_hooks ~w(stop subagent-stop)

  # Every shape `explain/2` and `summarize/1` handle. It listed six and six were
  # already being passed — `{:not_connected, probe}`, `{:unknown_harness, id}`,
  # `{:server_unreachable, id, reason}` and `:no_harness` all arrive here from
  # `HooksController` and none of them were declared.
  @type reason ::
          :not_connected
          | {:not_connected, {:http, pos_integer()} | {:error, term()}}
          | :no_project
          | :no_credential
          | :no_reply
          | :no_harness
          | :invalid_config
          | {:refused, term()}
          | {:unknown_harness, String.t()}
          | {:server_unreachable, String.t(), term()}

  @doc """
  The response for a hook the harness could not get an answer for.

  `payload` is the hook's own body — only `stop_hook_active` is read from it.
  """
  @spec unreachable(String.t(), reason(), String.t(), map()) :: map()
  def unreachable(hook, reason, working_dir, payload \\ %{}) do
    cond do
      hook not in @deciding_hooks ->
        %{"systemMessage" => advisory(hook, reason, working_dir)}

      already_blocked?(payload) ->
        %{"systemMessage" => second_pass(reason, working_dir)}

      true ->
        %{"decision" => "block", "reason" => refusal(reason, working_dir)}
    end
  end

  @doc "Whether a hook is one whose answer decides something."
  @spec deciding?(String.t()) :: boolean()
  def deciding?(hook), do: hook in @deciding_hooks

  @doc """
  One line naming what went wrong, for the log.

  `explain/2` already tells the agent which end is broken. The log did not:
  every refusal was written with `inspect/1` on the raw reason, so
  `harness.log` carried 284 lines of

      [CmsHarness] pre-tool-use refused for <dir>: {:not_connected, {:http, 200}}

  which reads as a contradiction — the server answered, and answered 200, and
  the line calls it not-connected. Both halves are true and the pairing is the
  useful part (the channel is down *and* the server is up, so restart the
  harness), but a tuple does not say that, and whoever is reading the log is by
  definition the person who cannot see the agent's copy.

  So the discriminator that `explain/2` already computes gets rendered here
  too, short enough for one line. Same clauses, same order; the two must not be
  able to disagree about which end is broken.
  """
  @spec summarize(reason()) :: String.t()
  def summarize({:not_connected, {:http, status}}) when status >= 500 do
    "channel down, server answering #{status} — server-side; the channel rejoins on its own"
  end

  def summarize({:not_connected, {:http, status}}) do
    "channel down, server answering #{status} — this harness cannot hold a socket; " <>
      "check the credential and the reconnect attempts, not the server"
  end

  def summarize({:not_connected, {:error, reason}}) do
    "channel down, server not answering at all: #{inspect(reason, limit: 3)}"
  end

  def summarize(:not_connected), do: "channel to the server is down"

  def summarize(:no_reply), do: "server was asked and did not answer in time"

  def summarize({:refused, detail}) do
    "server answered with an error rather than a decision: #{inspect(detail, limit: 5)}"
  end

  def summarize(:no_credential), do: "no credential — the harness never connected"

  def summarize(:no_project), do: "no project id for this directory"

  def summarize(:invalid_config), do: "config.yml found but no project id could be read from it"

  def summarize({:unknown_harness, id}) do
    "the server does not recognise harness #{id}, or has no location recorded for it"
  end

  def summarize({:server_unreachable, id, reason}) do
    "could not ask the server where #{id} is: #{inspect(reason, limit: 3)}"
  end

  def summarize(:no_harness), do: "the hook named no working copy"

  def summarize(other), do: inspect(other)

  defp already_blocked?(%{"stop_hook_active" => true}), do: true
  defp already_blocked?(_), do: false

  defp refusal(reason, working_dir) do
    """
    The CodeMySpec harness could not decide whether this turn is finished, so it is not saying that it is.

    #{explain(reason, working_dir)}

    This is not "there is nothing left to do" — the harness never got to ask. Fix the connection and stop again; the next stop will be a real answer.
    """
    |> String.trim()
  end

  defp second_pass(reason, working_dir) do
    """
    Stopping unverified: the CodeMySpec harness still could not reach the server, so nothing about this turn has been checked — not the compiler, not the tests, not the requirement graph.

    #{explain(reason, working_dir)}

    Treat this turn as unverified rather than clean.
    """
    |> String.trim()
  end

  defp advisory(hook, reason, working_dir) do
    """
    The CodeMySpec harness is not connected, so the #{hook} hook did nothing.

    #{explain(reason, working_dir)}
    """
    |> String.trim()
  end

  defp explain(:not_connected, working_dir) do
    """
    The harness is running but its channel to the CodeMySpec server is down, so it cannot reach the project's state. Check the harness log for the reconnect attempts.
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  # The channel is down and the server was asked whether it is up, so the
  # refusal can name which end is broken instead of hedging. It used to say
  # "the server itself may well be healthy"; the day that mattered, the server
  # was returning 500 and the hedge sent the reader to the harness.
  defp explain({:not_connected, {:http, status}}, working_dir) when status >= 500 do
    """
    The harness's channel to the CodeMySpec server is down, and the server is answering #{status}. This is the server, not the harness — the channel will rejoin on its own once the server is healthy. A dev server usually needs restarting rather than fixing: Phoenix cannot hot-reload a config or dependency change.
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  defp explain({:not_connected, {:http, status}}, working_dir) do
    """
    The harness's channel to the CodeMySpec server is down, but the server is answering (#{status}). So the server is up and this harness cannot hold a socket to it — look at the credential and the reconnect attempts in the harness log, not at the server.
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  # "Start it" was the whole of this, and starting it is not always enough.
  #
  # A build that is stale against the tree takes the server down again on its
  # first code-reload, with a message that reads as absurd on a server you have
  # just restarted: "You must restart your server after changing configuration
  # files". Phoenix treats a changed config as fatal to the reloader and can
  # never pick up a dependency that was added, so the restart boots, serves one
  # request, and dies (7e8fd1c6). Seen twice more since that report.
  #
  # The order matters and is the part nobody guesses: fetch and compile *before*
  # `phx.server`, because the failure is the build rather than the boot.
  defp explain({:not_connected, {:error, reason}}, working_dir) do
    """
    The harness's channel to the CodeMySpec server is down, and the server is not answering at all: #{inspect(reason)}. Start it, or point CMS_SERVER_URL somewhere that is running.

    If it has already been restarted and went down again, the build is stale against the tree rather than the boot being wrong: run `mix deps.get && mix compile` before `mix phx.server`. Phoenix cannot hot-reload a changed config or a new dependency, so a plain restart boots, serves one request, and dies on its first reload — saying you must restart a server you just restarted.
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  # A hook that named no working copy at all. There is deliberately nothing to
  # fall back on: resolving it from the directory it fired in is what this
  # replaced, and that guessed wrong in every way a guess can.
  defp explain(:no_harness, _working_dir) do
    """
    This hook did not say which working copy it is about.

    Hooks are addressed to a harness id. Run `mix cms.harness.onboard` in the \
    checkout to generate a plugin whose hooks carry one, and start the agent \
    with `--plugin-dir <checkout>/.claude/plugin-dev`.
    """
    |> String.trim()
  end

  # The server does not recognise the id, or has no location recorded for it.
  # Distinct from `:no_project`, which is about a directory that cannot say
  # which project it is — here there is no directory in the question at all,
  # so telling somebody to edit a config file in one would be nonsense.
  defp explain({:unknown_harness, harness_id}, _working_dir) do
    """
    This harness is not serving the working copy #{harness_id}.

    The hooks are addressed to a harness id the server does not recognise, or \
    one it has no location for. Re-run `mix cms.harness.onboard` in the \
    checkout and restart the agent.
    """
    |> String.trim()
  end

  # The id may be perfectly good — nobody got to check. Says so, because the
  # clause above used to answer this case too, and "the server does not
  # recognise your id" sends the reader to re-onboard a config that was never
  # wrong. Measured: `:4000` was down, the token exchange returned
  # `econnrefused`, and the refusal blamed the id.
  defp explain({:server_unreachable, harness_id, reason}, _working_dir) do
    """
    The harness could not reach the CodeMySpec server to find out where \
    #{harness_id} is: #{inspect(reason, limit: 5)}

    Nothing is wrong with the id, and re-onboarding will not help. The server \
    is down or unreachable from here — check that it is listening, then stop \
    again. `GET /health` on the harness reports `server_url`, which is the \
    address it tried.
    """
    |> String.trim()
  end

  defp explain(:no_project, working_dir) do
    """
    The harness is not serving this directory. It has no project id for it — set `project_id` in `#{Path.join(working_dir, ".code_my_spec/config.yml")}`, or set CMS_PROJECT_ID, and restart the harness.
    """
    |> String.trim()
  end

  defp explain(:invalid_config, working_dir) do
    """
    The harness found `#{Path.join(working_dir, ".code_my_spec/config.yml")}` but could not read a project id out of it.
    """
    |> String.trim()
  end

  defp explain(:no_credential, _working_dir) do
    """
    The harness has no credential for the CodeMySpec server, so it never connected. Set CMS_TOKEN (or CMS_DEPLOY_KEY for a sprite) and restart it.
    """
    |> String.trim()
  end

  # "The channel is joined" was asserted as evidence the connection was fine. It
  # is not: a channel that died mid-request is rebuilt in about a second, so by
  # the time anyone reads this it is joined again — and the request it was
  # carrying is gone. That reading sent three agents after a network problem
  # while the server was crashing on every stop, reconnecting, and doing it
  # again. So say how long the channel has been up, and let a fresh one point at
  # itself.
  defp explain(:no_reply, working_dir) do
    """
    The harness asked the CodeMySpec server and got no answer back in time.#{channel_age_note(ChannelClient.joined_ago(working_dir))}
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  defp explain({:refused, detail}, working_dir) do
    """
    The harness asked the CodeMySpec server and the server answered with an error rather than a decision. This is not a timeout and not a connection problem — the reply came back. The server said:

        #{inspect(detail)}
    #{likely_cause(detail)}
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  # Under a minute is the tell. A channel that has been up for hours really does
  # point at the server or the network; one that joined seconds ago was almost
  # certainly rebuilt after dying, which is a server-side crash and is logged as
  # `[HarnessProject] channel DIED` with the reason.
  @recent_join_seconds 60

  @doc false
  # Public so the three readings can be asserted without standing up a channel,
  # the same reason `McpController.error_page_summary/3` is. The message is the
  # whole of the fix here — the previous one was a correct sentence drawing the
  # wrong conclusion.
  def channel_age_note(joined_ago) do
    case joined_ago do
      nil ->
        " The channel is not joined, so the harness could not ask at all."

      ago when ago <= @recent_join_seconds ->
        " The channel is joined, but it only joined #{ago}s ago — it was very likely" <>
          " rebuilt after dying, which would have taken this request with it." <>
          " Look for `[HarnessProject] channel DIED` in the server's log; the reason" <>
          " is on that line."

      ago ->
        " The channel has been joined for #{ago}s, so this is the server or the" <>
          " network rather than the harness's connection state."
    end
  end

  # The server answered — it just did not answer with a decision. Rendering this
  # as `:no_reply` sent a reader looking at the network for an hour while the
  # server was replying promptly and saying exactly what was wrong. A refusal
  # and a silence are different failures with different fixes, and this module
  # exists to keep failures that read alike from *being* alike.
  #
  # The server's own words are quoted rather than summarised, because the shape
  # that arrives here is by definition one this harness did not anticipate.

  # Naming a cause is worth doing and worth being right about. "A version skew
  # is the usual cause" was asserted for every refusal, and an `unmatched topic`
  # is almost never skew — it is the server having no channel on a topic this
  # harness still believes it holds, which `ChannelClient.maybe_rejoin/2` exists
  # to correct by reconnecting. Sent as skew, it cost an investigation that
  # started at versions and had to work backwards through a healthy server, ten
  # clean joins and no crashes.
  #
  # One working copy per line of that story matters too: the topic is keyed on
  # the *project*, so with several checkouts of one project on this machine the
  # error names something all of them share.
  defp likely_cause(%{"reason" => "unmatched topic"}) do
    """

    The server has no channel on the topic this harness pushed to. That is
    usually a reconnect race rather than a version skew — the harness reconnects
    on seeing this, so stopping again is normally enough. If it repeats, check
    `GET /health` on the harness: the topic is keyed on the project, so several
    working copies of one project share it and the error cannot say which one is
    failing.#{boot_drift()}
    """
  end

  defp likely_cause(_detail) do
    """

    A version skew is one cause: a server that does not know an event this
    harness sends replies with an error rather than a decision.#{boot_drift()}
    """
  end

  # Turns that skew hypothesis into a fact where there is one.
  #
  # A harness runs the code it booted with, so a checkout that has moved
  # underneath it — a merge, a rebase, a branch switch — can leave its idea of
  # the channel contract behind the server's. `7e8fd1c6`: 137 commits merged
  # mid-session, and every stop afterwards failed with `unmatched topic` until
  # the harness was restarted. Nothing in the error connected the two, and the
  # skew line above was the closest thing to a lead.
  #
  # Only here, on the failure path. Drift is the normal state of an active
  # session and most commits do not touch the harness, so saying it proactively
  # would fire constantly and be ignored.
  #
  # Said on the `unmatched topic` clause as well as the generic one, because
  # drift is the only thing that separates its two causes. A reconnect race
  # clears itself on the next stop; a harness older than the running server
  # never does, and both arrive as the same string. Reported across all three
  # worktrees at once after a server restart, which is the skew case — the
  # advice to "stop again" was wrong for every one of them.
  #
  # Names the command, because the session that notices is the one least able to
  # act: a harness's command line is only `-S mix run --no-halt`, so its port,
  # server URL and launch directory are invisible to a peer process, and killing
  # it without a correct relaunch takes hooks down for every working copy.
  defp boot_drift do
    case CodeMySpec.BootVersion.drift() do
      {:drifted, booted, current} ->
        "\n\n    This harness booted from #{booted} and its checkout is now at " <>
          "#{current}." <>
          contract_verdict(CodeMySpec.BootVersion.contract_changed?(booted, current))

      :none ->
        ""
    end
  end

  # The condition answered, rather than handed to the reader. It used to say "if
  # that range touched the harness or the channel contract" — and the reader who
  # acted on it ran the `git diff --stat` themselves before believing it.
  defp contract_verdict(true) do
    " That range changed `lib/cms_harness` or the channel modules, so this " <>
      "harness is running an older contract than the server and reconnecting " <>
      "will not help. Restart it with `just refresh-harness`, which rediscovers " <>
      "the port and credential rather than needing them passed."
  end

  defp contract_verdict(false) do
    " That range did not touch `lib/cms_harness` or the channel modules, so " <>
      "skew is not the cause here — look elsewhere before restarting."
  end

  defp contract_verdict(:unknown) do
    " Whether that range touched the harness or the channel modules could not " <>
      "be read (a rebase can leave the booted commit unreachable). If in doubt, " <>
      "restart with `just refresh-harness`."
  end
end
