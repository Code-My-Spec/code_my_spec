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

  @deciding_hooks ~w(stop subagent-stop)

  @type reason :: :not_connected | :no_project | :no_credential | :no_reply | :invalid_config

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
    The harness is running but its channel to the CodeMySpec server is down, so it cannot reach the project's state. Check the harness log for the reconnect attempts; the server itself may well be healthy.
    Working directory: #{working_dir}
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

  defp explain(:no_reply, working_dir) do
    """
    The harness asked the CodeMySpec server and got no answer back in time. The channel is joined, so this is the server or the network rather than the harness's connection state.
    Working directory: #{working_dir}
    """
    |> String.trim()
  end
end
