defmodule CodeMySpec.Analysis.Alert do
  @moduledoc """
  Tells an agent, on its next tool call, that an analyzer run has landed.

  Rendered here, not in `Hooks`, because two transports deliver it: the
  post-tool-use hook (via the `Hooks.AnalysisAlert` shim) and
  `McpServers.AgentAlert` for agents under Alloy, which fire no hooks.

  Push the fact, pull the detail: the alert names sources, counts and age;
  `list_problems` has the rest. Scoped to the working copy, never to a session
  or file. See knowledge/analysis, "The analysis alert".
  """

  alias CodeMySpec.Problems
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation.Blocking

  @doc """
  A one-line alert for this session, or `nil` when there is nothing new to say.

  Silent when no run has landed since this recipient was last told, when the
  run landed clean, or when the caller names neither a session nor an agent.

  The silent path costs one query (`Problems.watermark/1`), because this runs
  on every tool call.
  """
  @spec check(Scope.t(), String.t() | nil, String.t() | nil) :: String.t() | nil
  def check(scope, session_id, agent_id \\ nil)

  # Either id makes a recipient: an external agent has a session id, an agent
  # under Alloy has only an agent id.
  def check(_scope, nil, nil), do: nil

  def check(%Scope{active_working_copy_id: working_copy_id} = scope, session_id, agent_id)
      when is_binary(working_copy_id) and (is_binary(session_id) or is_binary(agent_id)) do
    # One indexed query: problem count and latest change. Nothing is loaded.
    case Problems.watermark(scope) do
      {0, _} ->
        # Also the clean-run case: a green run leaves no problems.
        nil

      {_count, nil} ->
        nil

      {_count, latest} = mark ->
        who = {working_copy_id, session_id, agent_id}

        if already_told?(who, mark) do
          nil
        else
          record(who, mark)
          cached_message(working_copy_id, mark, scope, latest)
        end
    end
  end

  def check(_scope, _session_id, _agent_id), do: nil

  # Keyed per (copy, session, agent): a Task subagent shares its parent's
  # session, so a session-only key let one silence the other. Dedups the
  # notification, never the content. In memory: a restart costs one repeat.
  defp already_told?({_copy, _session, _agent} = who, mark) do
    :persistent_term.get({__MODULE__, who}, nil) == mark
  end

  defp record({_copy, _session, _agent} = who, mark) do
    :persistent_term.put({__MODULE__, who}, mark)
  end

  # First render of a mark is reused by every recipient, so two transports
  # told a second apart never get different `age/1` text for one event.
  defp cached_message(working_copy_id, mark, scope, latest) do
    key = {__MODULE__, :message, working_copy_id, mark}

    case :persistent_term.get(key, :unset) do
      :unset ->
        text = message(scope, latest)
        :persistent_term.put(key, text)
        text

      text ->
        text
    end
  end

  # Counts only what the gate would enforce: never-green spex are advisory,
  # and counting them put a permanent, unactionable number in every alert.
  defp message(scope, latest) do
    sources =
      scope
      |> enforceable_problems()
      |> Enum.frequencies_by(& &1.source)
      |> Enum.sort_by(fn {_source, n} -> -n end)
      |> Enum.map_join(", ", fn {source, n} -> "#{source}: #{n}" end)

    case sources do
      "" ->
        nil

      named ->
        # Capped: it rides on every tool call.
        String.slice(
          "#{named} failing in this working copy, #{age(latest)}. `list_problems` for detail",
          0,
          199
        )
    end
  end

  # Analysis is async; without the age an agent reads a stale count as a
  # verdict on the fix it just made.
  defp age(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 60 -> "as of #{max(s, 0)}s ago"
      s when s < 3600 -> "as of #{div(s, 60)}m ago"
      s -> "as of #{div(s, 3600)}h ago"
    end
  end

  defp age(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> age()

  defp enforceable_problems(scope) do
    scope
    |> Blocking.enforceable(Problems.list_project_problems(scope, []))
    |> then(&Blocking.blockable(scope, &1))
  end
end
