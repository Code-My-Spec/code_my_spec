defmodule CodeMySpec.MainAgent.CheckInReport do
  @moduledoc """
  The check-in, as the main agent reads it.

  One message carrying what every agent is doing, what is under them, and what
  is waiting — so the wake-up is an answer rather than an instruction to go and
  assemble one. Criterion 3332: a bare "time to check in" costs a turn before
  anything is known, seventy-two times a day, on the machine that is also
  running the agents.

  ## Here rather than beside the tool mappers

  It reads the same structs `list_agent_work` and `check_machinery` render, and
  it is tempting to compose it from their output. It cannot: those live in
  `McpServers`, which depends on this context and not the other way round. The
  dependency is the right way round — a check-in is something the main agent
  does, not something an MCP tool does — so the words are written here.

  What must not drift is the *facts*, and they cannot: both read the same
  structs. Two documents describing one fleet in two voices is fine; two
  describing it with different contents would not be.

  ## It says out loud when it found nothing

  "Nothing needs you" is a different sentence from an empty report, and the
  difference is criterion 3333's whole subject: a digest that could not be built
  is also empty, and only one of the two is good news.
  """

  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.MainAgent.Digest
  alias CodeMySpec.MainAgent.Machinery
  alias CodeMySpec.MainAgent.OpenQuestion

  @doc "The whole check-in as one message."
  @spec render(Digest.t()) :: String.t()
  def render(%Digest{} = digest) do
    """
    Check-in. #{verdict(digest)}

    #{agents(digest.work)}

    #{machinery(digest.machinery)}

    #{questions(digest.questions)}

    `list_agent_work` and `check_machinery` have the detail behind any of this.
    """
  end

  defp verdict(digest), do: said(Digest.quiet?(digest))

  defp said(true), do: "Nothing needs you — every agent is working or has nothing to do."
  defp said(false), do: "Some of this needs you."

  defp agents([]), do: "agents: none running."

  defp agents(work) do
    "agents: #{length(work)} running\n" <> Enum.map_join(work, "\n", &agent_line/1)
  end

  # Enough to decide whether to look closer, and no more. The full per-agent
  # view is `list_agent_work`, named above — a check-in that reproduced it would
  # be a wall of text seventy-two times a day, and the one agent that needed
  # attention would be somewhere in the middle of it.
  defp agent_line(%AgentWork{} = entry) do
    "  #{entry.agent_id} (#{entry.role}) — #{doing(entry)}; last said #{moment(entry.last_said_at)}"
  end

  defp doing(%AgentWork{task_name: nil} = entry) do
    cond do
      AgentWork.toolless?(entry) -> "cannot work, its machine reports no tools"
      entry.idle? -> "nothing to do"
      true -> "no task claimed"
    end
  end

  defp doing(%AgentWork{} = entry), do: "task: #{entry.task_name}"

  defp machinery(nil), do: "machinery: not read."

  defp machinery(%Machinery{tool_fault: :none}),
    do: "machinery: working — every agent's machine is answering."

  defp machinery(%Machinery{tool_fault: :machine}),
    do:
      "machinery: FAULTY — every agent on this project is on a machine reporting no " <>
        "tools. One fault underneath them; restarting agents will not reach it."

  defp machinery(%Machinery{tool_fault: {:agents, ids}}),
    do: "machinery: working, but these agents cannot call tools: " <> Enum.join(ids, ", ")

  defp questions([]), do: "questions: none open."

  defp questions(questions) do
    "questions: #{length(questions)} open\n" <> Enum.map_join(questions, "\n", &question_line/1)
  end

  defp question_line(%OpenQuestion{} = question) do
    "  #{Enum.join(OpenQuestion.texts(question), "; ")} (#{holder(question.holder)})"
  end

  defp holder("main_agent"), do: "yours to answer"
  defp holder(_holder), do: "waiting on the user"

  defp moment(nil), do: "never"
  defp moment(at), do: DateTime.to_iso8601(at)
end
