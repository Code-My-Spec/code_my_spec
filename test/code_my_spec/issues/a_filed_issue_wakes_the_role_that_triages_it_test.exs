defmodule CodeMySpec.Issues.AFiledIssueWakesTheRoleThatTriagesItTest do
  @moduledoc """
  Filing an issue wakes the role whose work it just became.

  `issues_triaged` is product's requirement and becomes actionable the moment an
  incoming issue exists. Nothing connected the two: `wake_roles/3` fires when a
  *task completes*, which covers "somebody finished something that unblocked
  you" and nothing else.

  So a product agent stopped correctly with an empty queue, said exactly what it
  was waiting for — "No product work is currently available; I'll stop and wait
  to be woken when a product requirement is unblocked" — and sat for ninety
  minutes while four issues were filed. The promise was true of task completions
  and of nothing else.

  What makes this safe to fire on every issue is that `StopDecision.wake/2`
  renders the menu and stays silent for a role with an empty one. A coding agent
  filing an issue mid-run does not wake itself or anybody with nothing to do.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  defp agent(scope, copy, role, continuous) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: continuous,
        working_copy: "/tmp/wake-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, _} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    agent
  end

  defp file_issue(scope) do
    {:ok, issue} =
      Issues.create_issue(scope, %{
        title: "something is wrong",
        description: "found while working on something else",
        severity: :medium
      })

    issue
  end

  defp woken(acc \\ []) do
    receive do
      {:agent_dispatch, id, _ref, message} -> woken([{id, message} | acc])
    after
      400 -> acc
    end
  end

  test "a product agent in the loop is told there is work", ctx do
    product = agent(ctx.scope, ctx.copy, "product", true)

    file_issue(ctx.scope)

    assert Enum.any?(woken(), fn {id, message} ->
             id == product.id and message =~ "Work of your kind is available"
           end),
           """
           An issue was filed and the role that triages it heard nothing. This is
           the ninety minutes of silence the agent was promised would end: it said
           it would wait to be woken when a product requirement was unblocked, and
           filing an issue is exactly that happening.
           """
  end

  # The half that keeps this from being a broadcast. An agent that is not in the
  # loop was not waiting to be woken, and waking it costs a turn nobody asked
  # for.
  test "an agent that is not in the loop is left alone", ctx do
    stopped = agent(ctx.scope, ctx.copy, "product", false)

    file_issue(ctx.scope)

    refute Enum.any?(woken(), fn {id, _message} -> id == stopped.id end),
           "an agent outside the loop was woken by an issue it never asked about"
  end

  # `wake/2` is menu-gated, so a role with nothing to do stays quiet even though
  # this fires project-wide. Without that this would charge every agent on the
  # project a turn for every issue anybody files.
  test "a role with nothing of its own is not charged a turn", ctx do
    qa = agent(ctx.scope, ctx.copy, "qa", true)

    file_issue(ctx.scope)

    refute Enum.any?(woken(), fn {id, _message} -> id == qa.id end),
           "QA has no issue-triage requirement and was woken to be told so"
  end
end
