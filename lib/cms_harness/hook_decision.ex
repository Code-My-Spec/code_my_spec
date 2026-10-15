defmodule CmsHarness.HookDecision do
  @moduledoc """
  What a hook answers when the harness could not ask.

  One module, so that "I asked and there is nothing to do" and "I could not
  ask" never render the same.

  * Name the end that is broken (harness or server), so the reader knows which
    process to look at.
  * The stop hook refuses: with no connection it cannot decide.
  * The one concession to livelock: on `stop_hook_active: true` (a stop already
    blocked once) the stop is allowed, with a `systemMessage` saying the turn
    was never verified.

  See knowledge/harness, "Hook decisions".
  """

  alias CmsHarness.Channel

  alias CodeMySpec.BootVersion

  @deciding_hooks ~w(stop subagent-stop)

  # The shapes `explain/3` and `summarize/2` handle (`{:not_onboarded, dir}`
  # too).
  @type reason ::
          :not_connected
          | {:not_connected, {:http, pos_integer()} | {:error, term()}}
          | :no_project
          | :no_credential
          | :no_reply
          | :no_harness
          | :invalid_config
          | :restarting
          | {:refused, term()}
          | {:unknown_harness, String.t()}
          | {:server_unreachable, String.t(), term()}

  @doc """
  The response for a hook the harness could not get an answer for.

  `payload` is the hook's own body — only `stop_hook_active` is read from it.
  """
  @spec unreachable(String.t(), reason(), String.t(), map()) :: map()
  def unreachable(hook, reason, working_dir, payload \\ %{}) do
    unreachable(hook, reason, working_dir, payload, channel_state(reason, working_dir))
  end

  @doc "Build a refusal using an already captured channel state."
  def unreachable(hook, reason, working_dir, payload, state) do
    explanation = explain(reason, working_dir, state)

    cond do
      hook not in @deciding_hooks ->
        %{"systemMessage" => advisory(hook, explanation)}

      already_blocked?(payload) ->
        %{"systemMessage" => second_pass(explanation)}

      true ->
        %{"decision" => "block", "reason" => refusal(explanation)}
    end
  end

  @doc "Whether a hook is one whose answer decides something."
  @spec deciding?(String.t()) :: boolean()
  def deciding?(hook), do: hook in @deciding_hooks

  @doc """
  One line naming what went wrong, for the log.

  The same discrimination `explain/3` makes for the agent, short enough for
  one log line. Same clauses, same order: the two must never disagree about
  which end is broken.
  """
  @spec summarize(reason()) :: String.t()
  def summarize(reason), do: summarize(reason, channel_state(reason, nil))

  @doc "Summarize a failure using an already captured channel state."
  def summarize({:not_connected, {:http, status}}, _state) when status >= 500 do
    "channel down, server answering #{status} — server-side; the channel rejoins on its own"
  end

  def summarize({:not_connected, {:http, status}}, state) do
    if state.holds_channel? do
      "this copy's channel is not up yet — the harness holds one for another " <>
        "copy, so the socket and the credential are both fine"
    else
      summarize_disconnected(status)
    end
  end

  def summarize({:not_connected, {:error, reason}}, _state) do
    "channel down, server not answering at all: #{inspect(reason, limit: 3)}"
  end

  def summarize(:not_connected, _state), do: "channel to the server is down"

  def summarize(:no_reply, _state), do: "server was asked and did not answer in time"

  def summarize({:refused, detail}, _state) do
    "server answered with an error rather than a decision: #{inspect(detail, limit: 5)}"
  end

  def summarize(:no_credential, _state), do: "no credential — the harness never connected"

  def summarize(:no_project, _state), do: "no project id for this directory"

  def summarize(:invalid_config, _state),
    do: "config.yml found but no project id could be read from it"

  def summarize(:restarting, _state), do: "the harness is restarting"

  def summarize({:unknown_harness, id}, _state) do
    "the server does not recognise harness #{id}, or has no location recorded for it"
  end

  def summarize({:server_unreachable, id, reason}, _state) do
    "could not ask the server where #{id} is: #{inspect(reason, limit: 3)}"
  end

  def summarize(:no_harness, _state), do: "the hook named no working copy"

  def summarize({:not_onboarded, dir}, _state) do
    "the hook fired in #{dir}, which is a project with no .cms_harness.json"
  end

  def summarize(other, _state), do: inspect(other)

  defp already_blocked?(%{"stop_hook_active" => true}), do: true
  defp already_blocked?(_), do: false

  defp refusal(explanation) do
    """
    The CodeMySpec harness could not decide whether this turn is finished, so it is not saying that it is.

    #{explanation}

    This is not "there is nothing left to do" — the harness never got to ask. Fix the connection and stop again; the next stop will be a real answer.
    """
    |> String.trim()
  end

  defp second_pass(explanation) do
    """
    Stopping unverified: the CodeMySpec harness still could not reach the server, so nothing about this turn has been checked — not the compiler, not the tests, not the requirement graph.

    #{explanation}

    Treat this turn as unverified rather than clean.
    """
    |> String.trim()
  end

  defp advisory(hook, explanation) do
    """
    The CodeMySpec harness is not connected, so the #{hook} hook did nothing.

    #{explanation}
    """
    |> String.trim()
  end

  defp explain(:not_connected, working_dir, _state) do
    """
    The harness is running but its channel to the CodeMySpec server is down, so it cannot reach the project's state. Check the harness log for the reconnect attempts.
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  # The server was probed, so the refusal names the broken end. A 5xx is
  # server-side whatever else is joined. Otherwise, if this harness holds a
  # channel for another copy, socket and credential are fine and this copy's
  # channel is still joining (first contact, or a restart's lease lapsing).
  defp explain({:not_connected, {:http, status}}, working_dir, _state) when status >= 500 do
    explain_disconnected({:not_connected, {:http, status}}, working_dir)
  end

  defp explain({:not_connected, {:http, status}}, working_dir, state) do
    if state.holds_channel? do
      """
      This working copy's channel to the CodeMySpec server has not come up yet. The harness is connected and holding a channel for another working copy, so the socket and the credential are both fine — neither is what to look at.
      A copy is picked up on its first contact, and a harness that was just restarted keeps a lease on the others for up to a minute. Try again shortly; if it persists, `/health` on the harness lists which roots it is serving.
      Working directory: #{working_dir}
      """
      |> String.trim()
    else
      explain_disconnected({:not_connected, {:http, status}}, working_dir)
    end
  end

  # Includes the stale-build remedy: Phoenix cannot reload a changed config or
  # new dependency, so fetch and compile before `phx.server`.
  defp explain({:not_connected, {:error, reason}}, working_dir, _state) do
    """
    The harness's channel to the CodeMySpec server is down, and the server is not answering at all: #{inspect(reason)}. Start it, or point CMS_SERVER_URL somewhere that is running.

    If it has already been restarted and went down again, the build is stale against the tree rather than the boot being wrong: run `mix deps.get && mix compile` before `mix phx.server`. Phoenix cannot hot-reload a changed config or a new dependency, so a plain restart boots, serves one request, and dies on its first reload — saying you must restart a server you just restarted.
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  # Neither an id nor a `cwd` inside an onboarded checkout. Hooks resolve from
  # the payload's `cwd` (`ResolveWorkingCopy`), so the remedy is where the
  # agent runs.
  defp explain(:no_harness, working_dir, _state) do
    """
    This hook did not say which working copy it is about: it named no harness \
    id, and #{no_harness_where(working_dir)}.

    A hook is resolved by walking up from the `cwd` in its payload to the \
    checkout's `.cms_harness.json`, so the agent must run inside the checkout. \
    If that file already exists, re-running `mix cms.harness.onboard` will not \
    help: start the agent from the checkout. If it does not, run \
    `mix cms.harness.onboard <checkout>`.
    """
    |> String.trim()
  end

  # The server does not recognise the id, or has no location for it. No
  # directory is involved, unlike `:no_project`.
  defp explain({:unknown_harness, working_copy_id}, _working_dir, _state) do
    """
    This harness is not serving the working copy #{working_copy_id}.

    The hooks are addressed to a harness id the server does not recognise, or \
    one it has no location for. Re-run `mix cms.harness.onboard` in the \
    checkout and restart the agent.
    """
    |> String.trim()
  end

  # Nobody got to check the id, so it must not be blamed.
  defp explain({:server_unreachable, working_copy_id, reason}, _working_dir, _state) do
    """
    The harness could not reach the CodeMySpec server to find out where \
    #{working_copy_id} is: #{inspect(reason, limit: 5)}

    Nothing is wrong with the id, and re-onboarding will not help. The server \
    is down or unreachable from here — check that it is listening, then stop \
    again. `GET /health` on the harness reports `server_url`, which is the \
    address it tried.
    """
    |> String.trim()
  end

  defp explain(:no_project, working_dir, _state) do
    """
    The harness is not serving this directory. It has no project id for it — set `project_id` in `#{Path.join(working_dir, ".code_my_spec/config.yml")}` and restart the harness.
    """
    |> String.trim()
  end

  defp explain(:restarting, _working_dir, _state) do
    "The harness is restarting — a promote restarts it. Stop again in a few seconds."
  end

  defp explain(:invalid_config, working_dir, _state) do
    """
    The harness found `#{Path.join(working_dir, ".code_my_spec/config.yml")}` but could not read a project id out of it.
    """
    |> String.trim()
  end

  # The `cwd` is a project (`.git` or `mix.exs`) with no harness config. The
  # walk stops at that boundary, so a checkout never adopts its parent's
  # identity.
  defp explain({:not_onboarded, dir}, _working_dir, _state) do
    """
    #{dir} has not been onboarded, so this harness has no identity for it.

    Run `mix cms.harness.onboard #{dir}` there. Until then nothing in this \
    checkout is recorded — its files, problems and analysis all key on an id it \
    does not have.

    The MCP tools do not go through this path and work meanwhile.
    """
    |> String.trim()
  end

  defp explain(:no_credential, _working_dir, _state) do
    """
    The harness has no credential for the CodeMySpec server, so it never connected. Run `mix cms.harness.onboard` in this working copy, which records its deploy key in `.cms_harness.json`, and restart the harness.
    """
    |> String.trim()
  end

  # Says how long the channel has been up: one rebuilt seconds ago lost the
  # request when it died.
  defp explain(:no_reply, working_dir, state) do
    """
    The harness asked the CodeMySpec server and got no answer back in time.#{channel_age_note(state.joined_ago)}
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  defp explain({:refused, detail}, working_dir, _state) do
    """
    The harness asked the CodeMySpec server and the server answered with an error rather than a decision. This is not a timeout and not a connection problem — the reply came back. The server said:

        #{inspect(detail)}
    #{likely_cause(detail)}
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  # A channel joined under a minute ago was almost certainly rebuilt after a
  # server-side death (`[HarnessProject] channel DIED`).
  @recent_join_seconds 60

  @doc "Explain whether the channel was absent, recently rebuilt, or established."
  # Public so the three readings can be tested without a channel.
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

  # A refusal is not a silence: the server's words are quoted. `unmatched
  # topic` is usually a reconnect race (`ChannelClient.maybe_rejoin/2`), not
  # skew; the topic is keyed on the project, so it cannot name one copy.
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

  # Boot drift, on the failure path only (drift is normal; said proactively it
  # would be ignored). It is what separates a reconnect race from a harness
  # older than the server. Names the restart command, since a peer cannot see
  # the harness's port or launch directory.
  # See knowledge/harness, "Hook decisions".
  defp boot_drift do
    case BootVersion.drift() do
      {:drifted, booted, current} ->
        drift_sentence(BootVersion.stale_kind(), booted, current) <>
          contract_verdict(BootVersion.contract_changed?(booted, current))

      :none ->
        ""
    end
  end

  defp drift_sentence(:behind_upstream, booted, current) do
    # Restarting alone relaunches the same commit: pull first.
    "\n\n    This harness booted from #{booted} and its checkout is behind its " <>
      "upstream, which is at #{current}. Pull in that checkout first — restarting " <>
      "alone relaunches the same code."
  end

  defp drift_sentence(_kind, booted, current) do
    "\n\n    This harness booted from #{booted} and its checkout is now at #{current}."
  end

  # Answers whether the range touched the contract, rather than asking.
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

  defp no_harness_where(dir) when dir in [nil, "", "(none given)"],
    do: "its payload carried no `cwd`"

  defp no_harness_where(dir), do: "it fired in #{dir}, which is inside no onboarded checkout"

  defp summarize_disconnected(status) do
    "channel down, server answering #{status} — this harness cannot hold a socket; " <>
      "check the credential and the reconnect attempts, not the server"
  end

  # Does this harness hold a joined channel for anything at all?
  #
  # Checks the registry exists first: a raise here would turn a refusal into a
  # crash.
  defp channel_state({:not_connected, {:http, status}}, _working_dir) when status < 500,
    do: %{holds_channel?: holds_a_channel?()}

  defp channel_state(:no_reply, working_dir) when is_binary(working_dir),
    do: %{joined_ago: Channel.joined_ago(working_dir)}

  defp channel_state(_reason, _working_dir), do: %{}

  defp holds_a_channel? do
    case Process.whereis(CmsHarness.Registry) do
      nil -> false
      _pid -> Enum.any?(CmsHarness.Projects.list(), &CmsHarness.Projects.connected?/1)
    end
  end

  defp explain_disconnected({:not_connected, {:http, status}}, working_dir) when status >= 500 do
    """
    The harness's channel to the CodeMySpec server is down, and the server is answering #{status}. This is the server, not the harness — the channel will rejoin on its own once the server is healthy. A dev server usually needs restarting rather than fixing: Phoenix cannot hot-reload a config or dependency change.
    Working directory: #{working_dir}
    """
    |> String.trim()
  end

  defp explain_disconnected({:not_connected, {:http, status}}, working_dir) do
    """
    The harness's channel to the CodeMySpec server is down, but the server is answering (#{status}). So the server is up and this harness cannot hold a socket to it — look at the credential and the reconnect attempts in the harness log, not at the server.
    Working directory: #{working_dir}
    """
    |> String.trim()
  end
end
