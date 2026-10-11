defmodule CodeMySpec.Agents.Main.CheckInReport do
  @moduledoc """
  A compact check-in from the same domain facts as the fleet detail tools.

  Names only agents needing attention. Settled/off seats and questions held by
  someone else are counts; valid read calls lead to the underlying evidence.
  Rendering suggests no answer or lifecycle change on main's behalf.
  """

  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Agents.Main.Machinery
  alias CodeMySpec.Agents.Main.OpenQuestion

  @work_offer "Your work: eligible work is waiting. Call get_next_requirement, then " <>
                "claim with start_task; nothing has been selected or assigned for you."

  @doc "Whether the digest has a decision or investigation for main, not merely a waiting user."
  def needs_attention?(%Digest{failed: reason}) when is_binary(reason), do: true

  def needs_attention?(%Digest{} = digest) do
    Enum.any?(digest.questions, &(&1.holder == "main_agent")) or
      Enum.any?(attention_agents(digest), &(not waiting_elsewhere?(&1, digest.questions))) or
      not is_nil(machinery_alarm(digest))
  end

  @spec render(Digest.t(), keyword()) :: String.t()
  def render(digest, opts \\ [])

  def render(%Digest{failed: reason}, _opts) when is_binary(reason),
    do: "Check-in FAILED: #{summary(reason)} — run_script: check_machinery({})"

  def render(%Digest{} = digest, opts) do
    render_digest(
      digest,
      opts,
      not needs_attention?(digest) and not Keyword.get(opts, :work?, false)
    )
  end

  defp render_digest(digest, _opts, true) do
    waiting = length(attention_agents(digest))

    "Check-in. #{quiet_verdict(digest.requirements)} " <>
      "#{length(digest.work) - waiting} settled; #{waiting} waiting; #{length(digest.off)} off " <>
      "(leave off). run_script: list_agent_work({}); list_agents({}). " <>
      question_counts(digest.questions) <> " " <> requirements(digest.requirements)
  end

  defp render_digest(digest, opts, false) do
    {mine, others} = Enum.split_with(digest.questions, &(&1.holder == "main_agent"))
    attention = attention_agents(digest)
    new_stalls = Keyword.get(opts, :new_stalls, [])
    needs = Enum.map(mine, &question_line/1) ++ Enum.map(attention, &agent_line(&1, new_stalls))
    needs = needs ++ List.wrap(machinery_alarm(digest))

    [
      "Check-in.",
      needs_block(needs),
      work(Keyword.get(opts, :work?, false)),
      "agents: #{length(digest.work) - length(attention)} settled; #{length(attention)} needing attention; " <>
        "#{length(digest.off)} off (leave off). run_script: list_agent_work({}); list_agents({})",
      question_counts(others),
      requirements(digest.requirements)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp quiet_verdict({:unavailable, _}), do: "Requirement progress could not be read."
  defp quiet_verdict(_requirements), do: "Nothing needs you."

  defp needs_block([]), do: "Nothing is waiting on main."
  defp needs_block(lines), do: "Needs you:\n" <> Enum.map_join(lines, "\n", &("- " <> &1))
  defp work(true), do: @work_offer
  defp work(false), do: nil

  defp attention_agents(digest) do
    stalled = MapSet.new(Digest.stalled(digest), & &1.agent_id)

    Enum.filter(digest.work, fn entry ->
      MapSet.member?(stalled, entry.agent_id) or entry.problems != [] or
        entry.blocked_reasons != [] or entry.task_status == :blocked or
        entry.agent_status in [:starting, :pending] or
        AgentWork.toolless?(entry) or AgentWork.provider_blocked?(entry) or
        AgentWork.timing_out?(entry)
    end)
  end

  defp waiting_elsewhere?(entry, questions) do
    Enum.any?(questions, &(&1.agent_id == entry.agent_id and &1.holder != "main_agent")) and
      entry.problems == [] and not AgentWork.toolless?(entry) and
      not AgentWork.provider_blocked?(entry) and not AgentWork.timing_out?(entry) and
      entry.agent_status not in [:starting, :pending]
  end

  defp question_line(%OpenQuestion{} = question) do
    text = question.title || "Decision needed"
    "#{question.kind} #{question.id}: #{summary(text)} — run_script: list_notifications({})"
  end

  defp agent_line(entry, new_stalls) do
    "#{entry.role} agent #{entry.agent_id}#{new_mark(entry.agent_id in new_stalls)}: " <>
      agent_reason(entry) <>
      " — run_script: read_agent_conversation({agent_id = " <>
      inspect(entry.agent_id) <> ", limit = 5})"
  end

  defp new_mark(true), do: " (new)"
  defp new_mark(false), do: ""

  defp agent_reason(entry) do
    cond do
      AgentWork.toolless?(entry) ->
        "cannot call tools"

      AgentWork.provider_blocked?(entry) ->
        "blocked on: " <> summary(AgentWork.provider_block(entry))

      AgentWork.timing_out?(entry) ->
        AgentWork.turn_timeouts(entry)

      entry.blocked_reasons != [] or entry.task_status == :blocked ->
        "blocked; inspect the waiting work"

      entry.agent_status in [:starting, :pending] ->
        "starting; inspect startup progress"

      entry.problems != [] ->
        "#{length(entry.problems)} checkout problems"

      true ->
        "STALLED: unclaimed work; inspect before intervening"
    end
  end

  defp machinery_alarm(%Digest{work: [_ | _] = work} = digest) do
    case Enum.all?(work, &AgentWork.provider_blocked?/1) do
      true ->
        "machinery: BLOCKED — every agent's provider is refusing; run_script: check_machinery({})"

      false ->
        machinery_alarm(digest.machinery)
    end
  end

  defp machinery_alarm(%Digest{machinery: machinery}), do: machinery_alarm(machinery)
  defp machinery_alarm(nil), do: nil
  defp machinery_alarm(%Machinery{tool_fault: :none}), do: nil

  defp machinery_alarm(%Machinery{tool_fault: :machine}),
    do: "machinery: FAULTY — shared tool fault; run_script: check_machinery({})"

  defp machinery_alarm(%Machinery{tool_fault: {:agents, ids}}),
    do: "machinery: #{length(ids)} agents cannot call tools; run_script: check_machinery({})"

  defp question_counts([]), do: "questions: none waiting on user or product."

  defp question_counts(questions) do
    counts = Enum.frequencies_by(questions, & &1.holder)

    "questions waiting on others: user #{Map.get(counts, "user", 0)}; " <>
      "product #{Map.get(counts, "product_agent", 0)}. run_script: list_notifications({})"
  end

  defp requirements(%{total: total, satisfied: satisfied}),
    do:
      "Requirements: #{satisfied}/#{total} satisfied. run_script: list_requirements({status = \"unsatisfied\", summary = true})"

  defp requirements({:unavailable, reason}),
    do:
      "Requirements: unavailable — #{summary(reason)}. run_script: list_requirements({status = \"unsatisfied\", summary = true})"

  defp requirements(nil),
    do:
      "Requirements: unavailable. run_script: list_requirements({status = \"unsatisfied\", summary = true})"

  defp summary(text), do: text |> String.replace(~r/\s+/, " ") |> String.slice(0, 160)
end
