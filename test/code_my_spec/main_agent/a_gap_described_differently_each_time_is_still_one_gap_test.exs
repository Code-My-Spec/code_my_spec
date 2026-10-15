defmodule CodeMySpec.Agents.Main.AGapDescribedDifferentlyEachTimeIsStillOneGapTest do
  @moduledoc """
  Issue bb784152 and its duplicates 1a41b25f, 2f67ccdf: `answer_question/4`'s
  `:worked_around` was both the gap's dedupe key and its prose explanation.
  Worded differently on three separate occasions, the same missing capability
  (`submit_issue_qa_result`, carried by the qa role the whole time) became
  three `capability_gaps` rows and three filed issues, each reporting "1
  times" because none of them matched any of the others byte for byte.

  `:capability` is now the caller's own stable name for what was missing;
  `:worked_around` is kept as evidence rather than as the key.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Main.GapRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.Notifications
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id}

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        status: :running,
        continuous: true,
        working_copy: "/tmp/gap-wording-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    %{scope: scope, agent: agent}
  end

  defp ask(scope, agent, text) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        agent.id,
        %{
          "title" => text,
          "questions" => [%{"question" => text, "options" => []}],
          "holder" => "main_agent"
        }
      )

    request
  end

  test "three different wordings of one missing capability file one issue, not three", ctx do
    wordings = [
      "the qa role could not submit a QA result for an issue, so I did it on its behalf",
      "I had to submit the issue QA result myself; qa has no tool for that",
      "qa lacks a way to submit an issue's QA result, so I supplied one"
    ]

    results =
      Enum.map(wordings, fn wording ->
        request = ask(ctx.scope, ctx.agent, wording)

        {:ok, _answered} =
          MainAgent.answer_question(ctx.scope, request.id, ctx.scope.active_working_copy_id,
            basis: "record",
            worked_around: wording,
            capability: "submit_issue_qa_result"
          )
      end)

    assert length(results) == 3

    [gap] = GapRepository.list(ctx.scope.active_project_id)

    assert gap.occurrences == 3,
           "three different wordings of the same capability produced " <>
             "#{inspect(GapRepository.list(ctx.scope.active_project_id))} instead of one row " <>
             "counted three times"

    assert gap.detail == List.last(wordings),
           "the row's detail should be the most recent wording, not stuck on the first"

    issue = Issues.get_issue(ctx.scope, gap.issue_id)
    refute is_nil(issue), "the gap has no issue attached at all"

    assert issue.title == MainAgent.gap_title(%{role: "qa", capability: "submit_issue_qa_result"})
    assert issue.description =~ "3 times"
    assert issue.description =~ List.last(wordings)

    matching_issues =
      ctx.scope
      |> Issues.list_issues()
      |> Enum.filter(&(&1.title == issue.title))

    assert length(matching_issues) == 1,
           "the same capability, described three different ways, still filed " <>
             "#{length(matching_issues)} issues instead of one"
  end

  test "without an explicit capability, identical wording still dedupes as before", ctx do
    wording = "the qa role cannot read its own question queue"

    for _ <- 1..2 do
      request = ask(ctx.scope, ctx.agent, wording)

      {:ok, _} =
        MainAgent.answer_question(ctx.scope, request.id, ctx.scope.active_working_copy_id,
          basis: "record",
          worked_around: wording
        )
    end

    [gap] = GapRepository.list(ctx.scope.active_project_id)
    assert gap.occurrences == 2
    assert gap.detail == wording
  end
end
