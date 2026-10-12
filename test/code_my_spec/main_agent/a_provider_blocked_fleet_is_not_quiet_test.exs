defmodule CodeMySpec.Agents.Main.AProviderBlockedFleetIsNotQuietTest do
  @moduledoc """
  An agent its provider refused reads as blocked on the provider, everywhere.

  Issue 044599cc: with every agent's codex account out of credits, `check_in`
  said "machinery: working — every agent's machine is answering" and
  `list_agent_work` said "blocked on: nothing" for two hours.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Main.{AgentWork, CheckInReport, Digest, Machinery}
  alias CodeMySpec.McpServers.MainAgent.AgentWorkMapper

  @refusal "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to " <>
             "purchase more credits or try again at Sep 30th, 2026 11:20 PM."

  defp entry(overrides) do
    struct!(
      %AgentWork{
        agent_id: Ecto.UUID.generate(),
        role: :coding,
        agent_status: :running,
        working_copy_id: Ecto.UUID.generate(),
        task_name: "architecture_designed",
        task_status: :active,
        idle?: false,
        turn_started_at: nil,
        tapped_out?: false,
        blocked_reasons: [],
        problems: [],
        machine_tools: ["promote"]
      },
      overrides
    )
  end

  defp refused(overrides \\ []),
    do:
      entry(
        [provider_refusal: @refusal, provider_retry_at: ~U[2026-09-30 23:20:00.000000Z]] ++
          overrides
      )

  defp digest(work),
    do: %Digest{questions: [], machinery: %Machinery{tool_fault: :none}, work: work}

  test "a provider-blocked agent is not quiet" do
    refute Digest.quiet?(digest([refused()]))
    assert Digest.quiet?(digest([entry([])]))
  end

  test "a provider-blocked agent with no task is not called stalled" do
    report = CheckInReport.render(digest([refused(task_name: nil, task_status: nil)]))

    refute report =~ "STALLED"
    assert report =~ "blocked on: provider — You've hit your usage limit"
  end

  test "the check-in names the provider problem and points to its details" do
    agent = refused()
    report = CheckInReport.render(digest([agent]))
    assert report =~ "blocked on: provider"
    assert report =~ "You've hit your usage limit"
    assert report =~ "read_agent_conversation({agent_id = #{inspect(agent.agent_id)}, limit = 5})"
  end

  test "the machinery line does not call a fully refused fleet working" do
    report = CheckInReport.render(digest([refused(), refused(role: :qa)]))

    refute report =~ "every agent's machine is answering"
    assert report =~ "machinery: BLOCKED — every agent's provider is refusing"
  end

  test "one refused agent among working ones leaves the machinery line alone" do
    report = CheckInReport.render(digest([refused(), entry([])]))

    refute report =~ "machinery: BLOCKED"
    assert report =~ "1 settled; 1 needing attention"
  end

  test "list_agent_work says what the agent is blocked on" do
    text = AgentWorkMapper.text([refused(blocked_reasons: ["which schema?"])])

    assert text =~
             "blocked on: provider — #{@refusal} (retry after 2026-09-30T23:20:00.000000Z); " <>
               ~s(an unanswered question: "which schema?")

    assert AgentWorkMapper.text([entry([])]) =~ "blocked on: nothing"
  end
end
