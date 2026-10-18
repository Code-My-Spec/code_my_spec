defmodule CodeMySpec.Agents.AnOffAgentsQuestionIsNeverMovedByAStartTest do
  @moduledoc """
  Issue d1f06141 (and its spread): an earlier fix for story 1023 handed an off
  (stopped, not retired) agent's pending question to the first new same-role
  agent to start anywhere in the project. A brand-new scratch copy's agent
  that had never spoken inherited a months-old question from an unrelated
  agent on an unrelated copy; when that scratch agent was in turn stopped, the
  same question moved again, onto a different team's working agent on a
  different story. Both broke criterion 1236 (a question's asker and checkout
  never change) and criterion 1233 (a question from a stopped agent stays
  attributed to that agent, not lost, and not moved to a new one either).

  Retiring an agent still hands its question to a successor anywhere in the
  project (`retiring_an_agent_hands_off_its_questions_test.exs`) -- retiring is
  permanent, so that seat's role is gone for good and *something* has to read
  the question. An agent that is merely off can come back: `turn_on_agent` is
  the only way back from off (`lib/code_my_spec/agents.ex`, `seat_is_on/2`),
  and resuming is the same row, so its question never needed to move at all.
  `start_agent` itself refuses outright to create a second row on the exact
  seat an off agent still holds -- so there is no reachable case where a
  genuinely new row replaces an off agent's own seat, and no case at all where
  it should inherit a question from an *unrelated* seat.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Notifications
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, feature} =
      WorkingCopies.issue(scope, nil, label: "a feature copy", device: device_fixture(scope))

    feature = with_root(feature, "feature")

    {:ok, other} =
      WorkingCopies.issue(scope, nil, label: "an unrelated copy", device: device_fixture(scope))

    other = with_root(other, "other")

    %{scope: scope, feature: feature, other: other}
  end

  # `put_destination/2` derives `working_copy` from the copy's own root and
  # overwrites whatever the caller passed, so every copy a start names needs
  # one or every start fails validation on a field the caller did supply.
  defp with_root(copy, label) do
    copy
    |> Ecto.Changeset.change(
      root: "/workspace/off-handoff-#{label}-#{System.unique_integer([:positive])}"
    )
    |> CodeMySpec.Repo.update!()
  end

  defp off_agent(scope, role, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        status: :stopped,
        working_copy: "/tmp/off-handoff-#{System.unique_integer([:positive])}",
        working_copy_id: copy_id
      })

    {:ok, off} = AgentsRepository.update_agent(scope, agent, %{off_at: DateTime.utc_now()})
    off
  end

  defp ask(scope, agent) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        agent.id,
        %{
          "title" => "Refund window",
          "holder" => "user",
          "questions" => [%{"question" => "14 or 30 days?", "options" => []}]
        },
        nil
      )

    request
  end

  defp owner(request), do: Notifications.get_question_request(request.id)

  defp start(scope, role, copy_id) do
    Agents.start_agent(scope, %{
      role: to_string(role),
      provider: "anthropic",
      working_copy_id: copy_id
    })
  end

  test "a same-role agent starting on an unrelated copy does not inherit an off agent's question",
       ctx do
    old = off_agent(ctx.scope, :product, ctx.feature.id)
    request = ask(ctx.scope, old)

    {:ok, elsewhere} = start(ctx.scope, :product, ctx.other.id)

    assert owner(request).agent_id == old.id,
           "a brand-new agent on an unrelated copy inherited another seat's old question"

    refute owner(request).agent_id == elsewhere.id
  end

  test "a brand-new scratch copy's own first agent starts with no inherited questions", ctx do
    old = off_agent(ctx.scope, :product, ctx.feature.id)
    request = ask(ctx.scope, old)

    {:ok, scratch} =
      WorkingCopies.issue(ctx.scope, nil, label: "scratch", device: device_fixture(ctx.scope))

    scratch = with_root(scratch, "scratch")

    {:ok, fresh} = start(ctx.scope, :product, scratch.id)

    assert owner(request).agent_id == old.id
    refute owner(request).agent_id == fresh.id
  end

  test "a different role starting elsewhere does not pick up the question either", ctx do
    old = off_agent(ctx.scope, :product, ctx.feature.id)
    request = ask(ctx.scope, old)

    {:ok, _coder} = start(ctx.scope, :coding, ctx.other.id)

    assert owner(request).agent_id == old.id
  end

  test "starting on the off agent's own exact seat is refused, not replaced", ctx do
    old = off_agent(ctx.scope, :product, ctx.feature.id)
    request = ask(ctx.scope, old)

    assert {:error, {:off, %{id: id}}} = start(ctx.scope, :product, ctx.feature.id)
    assert id == old.id

    assert owner(request).agent_id == old.id,
           "the question moved even though no new row was created for this seat"
  end

  test "the question stays visible and answerable while the agent is merely off", ctx do
    old = off_agent(ctx.scope, :product, ctx.feature.id)
    request = ask(ctx.scope, old)

    {:ok, answered} =
      Notifications.answer_question_request(request.id, %{"14 or 30 days?" => "30"})

    assert answered.agent_id == old.id
    assert answered.status == "answered"
  end

  test "offboarding an agent holding a question leaves no other running agent blocked on it",
       ctx do
    # `off_agent/3` simulates the offboard the same way the rest of this file
    # does, rather than driving the real `turn_off_agent/3` -- that path ends
    # a real process through a transport, which these fixture agents (never
    # launched through `start_agent`) have none to answer. The invariant this
    # proves does not depend on how the agent went off, only on what happens
    # (nothing) to its question once a *different* agent is on duty.
    asker = off_agent(ctx.scope, :product, ctx.feature.id)
    request = ask(ctx.scope, asker)

    {:ok, bystander} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        continuous: true,
        working_copy: "/tmp/off-handoff-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.other.id
      })

    CodeMySpecTest.AgentPresence.present(bystander)

    frame = %Frame{assigns: %{current_scope: ctx.scope}}

    reply =
      ToolLibrary.run(
        "list_agent_work",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    listing = response_text(reply)

    refute owner(request).agent_id == bystander.id,
           "an unrelated running agent inherited the offboarded asker's question"

    assert owner(request).agent_id == asker.id

    refute listing =~ ~r/#{bystander.id}[^\n]*blocked/i,
           "the bystander agent is reported blocked on a question it never asked. listing:\n#{listing}"
  end
end
