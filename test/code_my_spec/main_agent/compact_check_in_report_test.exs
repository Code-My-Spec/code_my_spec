defmodule CodeMySpec.Agents.Main.CompactCheckInReportTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.CheckInReport
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Agents.Main.Machinery
  alias CodeMySpec.Agents.Main.OpenQuestion

  defp settled(id),
    do: %AgentWork{agent_id: id, role: :coding, idle?: true, agent_status: :running}

  defp question(id, holder) do
    %OpenQuestion{
      id: id,
      holder: holder,
      title: "Choose retention",
      questions: [%{"question" => String.duplicate("private question body ", 100)}]
    }
  end

  test "hundreds of settled and off agents stay counts while attention keeps its identifier" do
    attention = %{settled("needs-attention") | idle?: false, continuous?: true}

    digest = %Digest{
      work: [attention | Enum.map(1..400, &settled("settled-#{&1}"))],
      off: Enum.map(1..200, &%Agent{id: "off-#{&1}", role: :coding}),
      machinery: %Machinery{tool_fault: :none}
    }

    report = CheckInReport.render(digest)
    assert report =~ "400 settled; 1 needing attention; 200 off"
    assert report =~ "coding agent needs-attention"
    refute report =~ "settled-"
    refute report =~ "off-"
    assert byte_size(report) < 700
    assert report =~ ~s|read_agent_conversation({agent_id = "needs-attention", limit = 5})|
    assert report =~ "list_agent_work({})"
    assert report =~ "list_agents({})"
  end

  test "questions owned elsewhere have counts but no IDs, titles or bodies" do
    digest = %Digest{
      questions:
        Enum.map(1..300, &question("user-#{&1}", "user")) ++
          Enum.map(1..200, &question("product-#{&1}", "product_agent"))
    }

    report = CheckInReport.render(digest)
    assert report =~ "user 300; product 200"
    refute report =~ "Choose retention"
    refute report =~ "private question"
    refute report =~ "user-"
    refute CheckInReport.needs_attention?(digest)
    assert byte_size(report) < 600
  end

  test "main's decision has a bounded summary and a read call, never a fabricated answer" do
    digest = %Digest{questions: [question("main-question", "main_agent")]}
    report = CheckInReport.render(digest)

    assert report =~
             "question main-question: Choose retention — run_script: list_notifications({})"

    refute report =~ "private question"
    refute report =~ "answer_notification"
    assert CheckInReport.needs_attention?(digest)
  end

  test "quiet is one line while failed inspection is never reassurance" do
    report = CheckInReport.render(%Digest{work: [settled("quiet")]})
    assert length(String.split(report, "\n")) == 1
    assert report =~ "Nothing needs you"
    refute report =~ "quiet"
    failed = CheckInReport.render(Digest.failed("ledger\nunavailable"))
    assert failed =~ "FAILED: ledger unavailable"
    assert failed =~ "check_machinery({})"
    refute failed =~ "Nothing needs you"
  end

  test "quiet fleet with admitted main work still carries discovery instructions" do
    report = CheckInReport.render(%Digest{}, work?: true)
    assert report =~ "get_next_requirement"
    assert report =~ "start_task"
    refute report =~ "Nothing needs you"
  end

  test "requirement totals are graph progress, never task attempts" do
    report = CheckInReport.render(%Digest{requirements: %{total: 800, satisfied: 600}})
    assert report =~ "Requirements: 600/800 satisfied"
    assert report =~ "list_requirements({status = \"unsatisfied\", summary = true})"
    assert length(String.split(report, "\n")) == 1
    refute report =~ "tasks"
  end

  test "unavailable graph progress remains explicit without becoming wake-worthy work" do
    digest = %Digest{requirements: {:unavailable, "graph has not been published"}}
    report = CheckInReport.render(digest)
    assert report =~ "Requirements: unavailable"
    refute report =~ "0/0"
    refute report =~ "Nothing needs you"
    refute CheckInReport.needs_attention?(digest)
    assert length(String.split(report, "\n")) == 1
  end
end
