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

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.MainAgent.Digest
  alias CodeMySpec.MainAgent.Machinery
  alias CodeMySpec.MainAgent.OpenQuestion

  @work_offer "Your work: eligible work is waiting. Call get_next_requirement to see it, " <>
                "then claim it with start_task. Nothing has been selected or assigned for you."

  @doc """
  The whole check-in as one message: what waits on main first — questions it
  answers, stalled teammates, a machinery fault, its own work — then the fleet.

  The cadence's turn (`MainAgent.cadence_check_in/3`) passes:

    * `:self` — main's own id, so its line reads "you".
    * `:work?` — main's work offer stands, so the turn carries it.
    * `:new_stalls` — ids that stalled since the last tick, marked new.
  """
  @spec render(Digest.t(), keyword()) :: String.t()
  def render(%Digest{} = digest, opts \\ []) do
    {mine, others} = Enum.split_with(digest.questions, &(&1.holder == "main_agent"))
    stalled = Digest.stalled(digest)
    alarm = machinery_alarm(digest.machinery, digest.work)
    needs = needs(mine, stalled, Keyword.get(opts, :new_stalls, []), alarm)

    [
      "Check-in. " <> verdict(digest, needs),
      needs_block(needs, mine),
      work(Keyword.get(opts, :work?, false)),
      agents(digest.work, Keyword.get(opts, :self), MapSet.new(stalled, & &1.agent_id)) <>
        off(digest.off),
      if(alarm, do: nil, else: machinery(digest.machinery)),
      questions(others, mine),
      "`list_agent_work` and `check_machinery` have the detail behind any of this."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp verdict(digest, needs) do
    cond do
      Digest.quiet?(digest) -> "Nothing needs you — every agent is working or has nothing to do."
      needs != [] -> "Some of this needs you."
      true -> "Nothing is waiting on you, but not every agent is settled — see below."
    end
  end

  defp needs(mine, stalled, new_stalls, alarm) do
    Enum.map(mine, &mine_line/1) ++
      Enum.map(stalled, &stall_line(&1, &1.agent_id in new_stalls)) ++ List.wrap(alarm)
  end

  defp needs_block([], _mine), do: nil

  defp needs_block(needs, mine) do
    "Needs you:\n" <>
      Enum.map_join(needs, "\n", &("- " <> &1)) <> answer_hint(mine)
  end

  # From the work prompt: the tool is code mode, and naming the wrong one cost a
  # main agent its turn (see `Work`'s `@prompt`).
  defp answer_hint([]), do: ""

  defp answer_hint(_mine),
    do:
      "\nRead questions with `run_script` calling list_notifications; answer each with " <>
        "`answer_notification` so the answer is recorded and reaches the asker."

  defp mine_line(%OpenQuestion{} = question) do
    "question #{question.id} from #{asker(question)}: " <>
      Enum.join(OpenQuestion.texts(question), "; ")
  end

  defp asker(%OpenQuestion{agent_id: nil}), do: "a session"

  defp asker(%OpenQuestion{} = question),
    do: "the #{question.agent_role} agent #{question.agent_id}#{root(question.working_copy_root)}"

  defp stall_line(%AgentWork{} = entry, new?) do
    "the #{entry.role} agent #{entry.agent_id} on working copy #{entry.working_copy_id}" <>
      "#{root(entry.working_copy_root)}#{if new?, do: " (new)", else: ""} — " <>
      AgentWork.unclaimed_work(entry)
  end

  defp root(nil), do: ""
  defp root(path), do: " (#{path})"

  defp work(true), do: @work_offer
  defp work(false), do: nil

  defp agents([], _self, _stalled), do: "agents: none running."

  defp agents(work, self, stalled) do
    "agents: #{length(work)} running\n" <>
      Enum.map_join(work, "\n", &agent_line(&1, self, stalled))
  end

  defp agent_line(%AgentWork{agent_id: id} = entry, id, _stalled),
    do: "  #{id} (#{entry.role}) — you"

  defp agent_line(%AgentWork{agent_id: id} = entry, _self, stalled) do
    if MapSet.member?(stalled, id),
      do: "  #{id} (#{entry.role}) — stalled, above",
      else: agent_line(entry)
  end

  # Printed so an off seat is not read as an empty one to staff (39af5611).
  defp off([]), do: ""

  defp off(agents) do
    "\nagents off: #{length(agents)} — leave them off unless you mean to turn one on\n" <>
      Enum.map_join(agents, "\n", &"  #{&1.id} (#{&1.role}) — #{Agent.describe_off(&1)}")
  end

  # Enough to decide whether to look closer, and no more. The full per-agent
  # view is `list_agent_work`, named above — a check-in that reproduced it would
  # be a wall of text seventy-two times a day, and the one agent that needed
  # attention would be somewhere in the middle of it.
  defp agent_line(%AgentWork{} = entry) do
    "  #{entry.agent_id} (#{entry.role}) — #{doing(entry)}#{provider(entry)}" <>
      "#{timeouts(entry)}; last said #{moment(entry.last_said_at)}"
  end

  defp timeouts(%AgentWork{} = entry) do
    case AgentWork.turn_timeouts(entry) do
      nil -> ""
      run -> "; " <> run
    end
  end

  defp provider(%AgentWork{} = entry) do
    if AgentWork.provider_blocked?(entry),
      do: "; blocked on: " <> AgentWork.provider_block(entry),
      else: ""
  end

  defp doing(%AgentWork{task_name: nil} = entry) do
    cond do
      AgentWork.toolless?(entry) -> "cannot work, its machine reports no tools"
      entry.idle? -> "nothing to do"
      true -> AgentWork.unclaimed_work(entry)
    end
  end

  defp doing(%AgentWork{} = entry), do: "task: #{entry.task_name}"

  # A machine answering is not an agent working: when every provider refuses,
  # nothing runs whatever the machines say (044599cc).
  # A fault is something main acts on, so it leads; a healthy line is fleet state.
  defp machinery_alarm(machinery, work) do
    cond do
      work != [] and Enum.all?(work, &AgentWork.provider_blocked?/1) ->
        "machinery: BLOCKED — every agent's provider is refusing its turns; nothing " <>
          "can run until it accepts them again."

      match?(%Machinery{tool_fault: fault} when fault != :none, machinery) ->
        machinery(machinery)

      true ->
        nil
    end
  end

  defp machinery(nil), do: "machinery: not read."

  defp machinery(%Machinery{tool_fault: :none}),
    do: "machinery: working — every agent's machine is answering."

  defp machinery(%Machinery{tool_fault: :machine}),
    do:
      "machinery: FAULTY — every agent on this project is on a machine reporting no " <>
        "tools. One fault underneath them; restarting agents will not reach it."

  defp machinery(%Machinery{tool_fault: {:agents, ids}}),
    do: "machinery: working, but these agents cannot call tools: " <> Enum.join(ids, ", ")

  # Main's own are under "Needs you"; these are the ones waiting on others.
  defp questions([], []), do: "questions: none open."
  defp questions([], _mine), do: nil

  defp questions(others, _mine) do
    "questions waiting on others: #{length(others)}\n" <>
      Enum.map_join(others, "\n", &question_line/1)
  end

  defp question_line(%OpenQuestion{} = question) do
    "  #{Enum.join(OpenQuestion.texts(question), "; ")} (#{holder(question.holder)})"
  end

  defp holder("product_agent"), do: "waiting on the product agent"
  defp holder(_holder), do: "waiting on the user"

  defp moment(nil), do: "never"
  defp moment(at), do: DateTime.to_iso8601(at)
end
