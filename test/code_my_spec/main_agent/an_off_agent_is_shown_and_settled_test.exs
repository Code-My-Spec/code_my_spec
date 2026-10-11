defmodule CodeMySpec.Agents.Main.AnOffAgentIsShownAndSettledTest do
  @moduledoc """
  Issue 39af5611. check_in and list_agent_work listed running agents only, so a
  seat somebody had stopped on purpose read as empty — a role to staff. An off
  agent is printed with who turned it off, when and why, and is settled: it is
  not STALLED and does not make the fleet non-quiet. Its open questions still
  show, and still count.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Main.CheckInReport
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Agents.Main.Machinery
  alias CodeMySpec.McpServers.MainAgent.AgentWorkMapper
  alias CodeMySpec.Notifications

  defp off_agent(overrides \\ %{}) do
    struct(
      %Agent{
        id: "965c52a9-0000-0000-0000-000000000000",
        role: :coding,
        status: :stopped,
        stopped_reason: :stopped,
        working_copy: "/tmp/metric_flow",
        off_at: ~U[2026-09-27 18:00:00.000000Z],
        off_by: "the Harness session",
        off_reason: "held until c1a64ee97 lands"
      },
      overrides
    )
  end

  @line "off — turned off by the Harness session (2026-09-27T18:00:00.000000Z): " <>
          "held until c1a64ee97 lands"

  defp digest(off, questions \\ []),
    do: %Digest{
      work: [],
      off: off,
      questions: questions,
      machinery: %Machinery{tool_fault: :none}
    }

  test "the check-in counts off seats and leaves their reasons in the detail listing" do
    digest = digest([off_agent()])

    assert Digest.quiet?(digest)
    report = CheckInReport.render(digest)
    assert report =~ "Nothing needs you"
    assert report =~ "1 off (leave off)"
    refute report =~ off_agent().id
    assert report =~ "list_agent_work({})"
    refute report =~ "STALLED"
  end

  test "a reason is optional in the line" do
    assert Agent.describe_off(off_agent(%{off_reason: nil})) ==
             "off — turned off by the Harness session (2026-09-27T18:00:00.000000Z)"
  end

  test "list_agent_work names it even with nothing running" do
    text =
      []
      |> AgentWorkMapper.listing([off_agent()])
      |> Response.to_protocol()
      |> Map.fetch!("content")
      |> hd()
      |> Map.fetch!("text")

    assert text =~ @line
    assert text =~ "turn_on_agent"
  end

  test "an off agent's open question still shows and still needs somebody" do
    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :stopped,
        working_copy: "/tmp/off-q-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id,
        off_at: DateTime.utc_now(),
        off_by: "the Harness session"
      })

    {:ok, _} =
      Notifications.create_question_request(scope.user.id, %{
        "title" => "A question",
        "agent_id" => agent.id,
        "questions" => [%{"question" => "Which schema?"}]
      })

    questions = MainAgent.list_open_questions(scope)
    assert Enum.any?(questions, &(&1.agent_id == agent.id))

    digest = digest(MainAgent.list_off_agents(scope), questions)
    refute Digest.quiet?(digest)
    assert CheckInReport.render(digest) =~ "user 1"
    refute CheckInReport.render(digest) =~ "Which schema?"
  end
end
