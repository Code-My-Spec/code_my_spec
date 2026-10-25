defmodule CodeMySpec.Agents.Main.CheckInReport do
  @moduledoc """
  A compact check-in from the same domain facts as the fleet detail tools.

  Names only agents needing attention. Settled/off seats and questions held by
  someone else are counts; valid read calls lead to the underlying evidence.
  Rendering suggests no answer or lifecycle change on main's behalf.
  """

  alias CodeMySpec.Agents.CompletionHandoffs
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Agents.Main.Machinery
  alias CodeMySpec.Agents.Main.OpenQuestion
  alias CodeMySpec.Agents.Main.TokenBurn

  @work_offer "Your work: eligible work is waiting. Call get_next_requirement, then " <>
                "claim with start_task; nothing has been selected or assigned for you."

  @doc "Whether the digest has a decision or investigation for main, not merely a waiting user."
  def needs_attention?(%Digest{failed: reason}) when is_binary(reason), do: true

  def needs_attention?(%Digest{} = digest) do
    Enum.any?(digest.questions, &(&1.holder == "main_agent")) or
      Enum.any?(attention_agents(digest), &(not waiting_elsewhere?(&1, digest.questions))) or
      not is_nil(machinery_alarm(digest)) or TokenBurn.over_threshold(digest.tokens) != []
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
      question_counts(digest.questions) <>
      " " <>
      requirements(digest.requirements) <>
      tokens_suffix(digest)
  end

  defp render_digest(digest, opts, false) do
    {mine, others} = Enum.split_with(digest.questions, &(&1.holder == "main_agent"))
    attention = attention_agents(digest)
    new_stalls = Keyword.get(opts, :new_stalls, [])
    needs = Enum.map(mine, &question_line/1) ++ Enum.map(attention, &agent_line(&1, new_stalls))
    needs = needs ++ List.wrap(machinery_alarm(digest)) ++ burn_lines(digest)

    [
      "Check-in.",
      needs_block(needs),
      case digest.completions do
        [] ->
          nil

        rows ->
          "Completions awaiting your acknowledgement:\n" <>
            Enum.map_join(rows, "\n", &CompletionHandoffs.message/1)
      end,
      work(Keyword.get(opts, :work?, false)),
      "agents: #{length(digest.work) - length(attention)} settled; #{length(attention)} needing attention; " <>
        "#{length(digest.off)} off (leave off). run_script: list_agent_work({}); list_agents({})",
      question_counts(others),
      requirements(digest.requirements),
      tokens_line(digest)
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
        starting?(entry) or AgentWork.toolless?(entry) or AgentWork.provider_blocked?(entry) or
        AgentWork.timing_out?(entry)
    end)
  end

  # A startup to watch: one a harness launches. An external session reads
  # `:starting` until a person drives it, and naming it every check-in cried wolf.
  defp starting?(%AgentWork{external?: true}), do: false
  defp starting?(entry), do: entry.agent_status in [:starting, :pending]

  defp waiting_elsewhere?(entry, questions) do
    Enum.any?(questions, &(&1.agent_id == entry.agent_id and &1.holder != "main_agent")) and
      entry.problems == [] and not AgentWork.toolless?(entry) and
      not AgentWork.provider_blocked?(entry) and not AgentWork.timing_out?(entry) and
      not starting?(entry)
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

      starting?(entry) ->
        "starting; inspect startup progress"

      entry.problems != [] ->
        "#{length(entry.problems)} checkout problems"

      true ->
        stall_reason(entry)
    end
  end

  # A turn handed over and never started says what was offered and when.
  defp stall_reason(%{unstarted_turn: nil}),
    do: "STALLED: unclaimed work; inspect before intervening"

  defp stall_reason(entry), do: AgentWork.unclaimed_work(entry)

  defp machinery_alarm(%Digest{work: [_ | _] = work} = digest) do
    if Enum.all?(work, &AgentWork.provider_blocked?/1),
      do:
        "machinery: BLOCKED — every agent's provider is refusing; run_script: check_machinery({})",
      else: machinery_alarm(digest.machinery)
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

  # Every check-in, quiet or not: the top three spenders over the last hour.
  defp tokens_line(%Digest{tokens: []}), do: nil

  defp tokens_line(%Digest{tokens: burn} = digest) do
    "tokens (1h): " <>
      Enum.map_join(Enum.take(burn, 3), "; ", fn entry ->
        "#{short(entry.agent_id)} #{role_of(digest, entry.agent_id)} " <>
          "#{millions(entry.tokens)}/#{entry.turns}t"
      end)
  end

  defp tokens_suffix(digest) do
    case tokens_line(digest) do
      nil -> ""
      line -> " " <> line
    end
  end

  # Spending past the threshold is a Needs-you entry, with the cheapest remedy.
  defp burn_lines(digest) do
    digest.tokens
    |> TokenBurn.over_threshold()
    |> Enum.map(fn entry ->
      "#{role_of(digest, entry.agent_id)} agent #{entry.agent_id}: burning tokens — " <>
        "#{millions(entry.tokens)} in the last hour over #{entry.turns} turns, largest turn " <>
        "#{millions(entry.largest_turn)}. Turn it off (run_script: turn_off_agent({agent_id = " <>
        inspect(entry.agent_id) <>
        "})); if it must keep working, retire it and start a fresh one."
    end)
  end

  defp role_of(digest, agent_id) do
    Enum.find_value(digest.work, "agent", &(&1.agent_id == agent_id && to_string(&1.role)))
  end

  defp short(agent_id), do: String.slice(agent_id, 0, 8)

  defp millions(:unknown), do: "unknown"
  defp millions(count) when count >= 1_000_000, do: "#{Float.round(count / 1_000_000, 1)}M"
  defp millions(count), do: "#{Float.round(count / 1_000_000, 2)}M"

  defp summary(text), do: text |> String.replace(~r/\s+/, " ") |> String.slice(0, 160)
end
