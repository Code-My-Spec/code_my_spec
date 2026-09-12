defmodule CodeMySpec.McpServers.MainAgent.AgentWorkMapper do
  @moduledoc """
  How the fleet is written out for the main agent to read.

  ## Every line is a fact, and the reader draws the conclusion

  Criterion 3275. There is no status word anywhere in this module, deliberately,
  and the two that look like one are not: "nothing to do" is the graph's answer
  about a role's queue, and "cannot work" is a machine that answered "I can run
  nothing" when asked what it can run.

  What is missing is the tempting part — `stalled`, `stuck`, `healthy`. Those
  would be computed from a silence threshold, which calls a streaming agent dead
  and a tapped-out one broken, and once printed the parts they came from are
  gone. So this prints how long ago, and lets the reader decide what that means.

  ## Absences are printed

  Every agent gets a `last said`, an `in flight` and a `problems` line whether
  or not there is anything to say, because "none" and "not checked" are
  different answers that render identically as nothing — criterion 3300. An
  absence that cannot be told from an omission is not information.
  """

  alias Anubis.Server.Response
  alias CodeMySpec.MainAgent.AgentWork

  @doc "Every agent on the project, with what it holds."
  @spec listing([AgentWork.t()]) :: Response.t()
  def listing([]) do
    Response.tool()
    |> Response.text("""
    No agents are running on this project.

    Nothing is being worked on, which is a different thing from nothing being
    left to do — `get_next_requirement` says whether there is work waiting.
    """)
  end

  def listing(work), do: Response.tool() |> Response.text(text(work))

  @doc """
  The same body as prose, for a caller composing a larger message.

  Shared rather than re-rendered so the check-in and the tool cannot drift into
  describing the same fleet two ways — which is how a reader learns to trust one
  of them and not the other.
  """
  @spec text([AgentWork.t()]) :: String.t()
  def text([]), do: "agents: none running on this project."

  def text(work) do
    "#{length(work)} agent(s) running.\n\n" <> Enum.map_join(work, "\n", &entry/1)
  end

  @doc "Why the fleet could not be read."
  @spec error(term()) :: Response.t()
  def error(reason) do
    Response.tool() |> Response.error("Could not read the agents: #{inspect(reason)}")
  end

  defp entry(%AgentWork{} = work) do
    """
    Agent: #{work.agent_id}
      role: #{work.role}
      working copy: #{work.working_copy_id}#{root(work)}
      #{holding(work)}
      last said: #{moment(work.last_said_at)}
      in flight: #{in_flight(work)}
      blocked on: #{blocked(work)}
      #{problems(work)}
    """
  end

  defp root(%AgentWork{working_copy_root: nil}), do: ""
  defp root(%AgentWork{working_copy_root: root}), do: " #{root}"

  # What the agent has in hand, and the two kinds of nothing.
  #
  # "Cannot work" is checked before "nothing to do" because a machine that can
  # run nothing has no queue worth reporting: the graph might well hold work for
  # its role, and saying so would send the main agent to wonder why it is not
  # being done.
  defp holding(%AgentWork{task_name: nil} = work) do
    cond do
      AgentWork.toolless?(work) ->
        "cannot work: its machine reports no tools, so every tool call it makes will fail"

      work.idle? ->
        "nothing to do: the graph holds no work for its role"

      true ->
        "no task claimed, and the graph does hold work for its role"
    end
  end

  defp holding(%AgentWork{} = work) do
    """
    task: #{work.task_name}#{story(work)}
      task opened: #{moment(work.task_started_at)}\
    """
  end

  defp story(%AgentWork{story_title: nil}), do: ""
  defp story(%AgentWork{story_title: title}), do: ~s( — "#{title}")

  # Always printed, and as a duration as well as a moment: how long a turn has
  # been running is what separates a long turn from a wedged one, and the
  # criterion is explicit that the main agent makes that call rather than
  # reading it here.
  defp in_flight(%AgentWork{turn_started_at: nil}), do: "nothing — no turn is open"

  defp in_flight(%AgentWork{turn_started_at: at}),
    do: "a turn opened #{moment(at)} and has not finished"

  defp blocked(%AgentWork{tapped_out?: true, blocked_reasons: []}), do: tapped_out()

  defp blocked(%AgentWork{tapped_out?: true} = work),
    do: tapped_out() <> "; " <> Enum.map_join(work.blocked_reasons, "; ", &quoted/1)

  defp blocked(%AgentWork{blocked_reasons: []}), do: "nothing"

  defp blocked(%AgentWork{blocked_reasons: reasons}),
    do: Enum.map_join(reasons, "; ", &quoted/1)

  defp tapped_out,
    do: "tapped out — it asked to leave the loop and a person has not answered yet"

  defp quoted(text), do: ~s(an unanswered question: "#{text}")

  # The findings themselves, not a count. "3 problems" against an agent is the
  # same errand one step later: the main agent still has to go and find out
  # whether they block the task it holds.
  defp problems(%AgentWork{problems: []}), do: "problems on this copy: none — it is clean"

  defp problems(%AgentWork{problems: found}) do
    lines =
      found
      |> Enum.take(10)
      |> Enum.map_join("\n    ", fn problem ->
        "[#{problem.source}] #{problem.file_path}:#{problem.line} #{problem.message}"
      end)

    "problems on this copy: #{length(found)}\n    #{lines}#{more(found)}"
  end

  # Named rather than silently dropped: a truncated list that does not say it is
  # truncated reads as the whole set.
  defp more(found) when length(found) > 10,
    do: "\n    …and #{length(found) - 10} more — `list_problems` has the rest"

  defp more(_found), do: ""

  defp moment(nil), do: "never"
  defp moment(at), do: DateTime.to_iso8601(at)
end
