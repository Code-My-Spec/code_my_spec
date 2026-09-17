defmodule CodeMySpec.McpServers.Tasks.Tools.HandingAnAgentWorkTest do
  @moduledoc """
  Issue `e15d1ff1`. `start_task`'s `agent_id` has always meant "who this task is
  for" — `execute/2`'s own comment says so — but the owner was resolved from the
  *caller*. So a task the main agent started for another agent landed on the main
  agent's session carrying that agent's id, and the agent it was for never saw
  it.

  Measured 2026-09-16: a task assigned to a QA agent came back from it as
  "`e7474578` no longer appears in this session's task list, so I used the live
  one". It was right, and the assignment had silently not happened. It only
  worked out because that agent already had an equivalent task of its own and
  was diligent enough to say so.

  ## Why this matters more than keeping an agent running

  The fleet is only useful if work can be aimed at it. Without this the levers
  are prose through `message_agent`, which an agent may read however it likes,
  and waiting for it to call `get_next_requirement` and choose for itself.
  Neither is assignment, so "put that agent on this story" had no implementation.

  ## What is deliberately unchanged

  The *caller* still comes off the connection and never out of the arguments.
  Naming a subject is not claiming to be one — that distinction is what
  `execute/2`'s comment protects and it survives here.

  Sub-agent labels (`aqa-1013-…` rather than a uuid) also still own tasks on the
  caller's session. They have no agent row to land on, and `fetch_agent/2` now
  answers `:not_found` for a non-uuid rather than raising, which is what lets
  that case fall through instead of crashing (`a4e338ae`).
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end

  defp a_project_with_an_agent do
    scope = CodeMySpec.ConfigurationsFixtures.require_all!(full_scope_fixture())
    component = component_fixture(scope, %{name: "List", module_name: "MyApp.List"})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "the agent's checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy_id: copy.id,
        working_copy: "/tmp/assign-#{System.unique_integer([:positive])}"
      })

    CodeMySpec.Requirements.recompute(scope)

    {scope, agent, component}
  end

  test "a task started for an agent lands where that agent will find it" do
    {scope, agent, component} = a_project_with_an_agent()

    # The main agent's position: a session, no agent id on the connection.
    session =
      session_fixture(scope,
        external_conversation_id: "sess-#{System.unique_integer([:positive])}"
      )

    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, started, _} =
      StartTask.execute(
        %{
          requirement_name: "spec_file",
          entity_type: "component",
          entity_id: component.id,
          session_id: session.external_conversation_id,
          agent_id: agent.id
        },
        frame
      )

    refute started.isError, text(started)

    # Now ask as the agent would: its own queue, from its own connection.
    agent_frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
    {:reply, listed, _} = ListTasks.execute(%{}, agent_frame)

    assert text(listed) =~ "spec_file",
           """
           The task was started for this agent and is not on its queue.

           This is the whole defect: the assignment reports success, the task
           lands on the caller's session carrying the agent's id, and the agent
           it was for never sees it. An agent told to work something it cannot
           find either does nothing or picks its own work instead.

           Got:\n#{text(listed)}
           """
  end

  test "a sub-agent label still owns its task on the caller's session" do
    {scope, _agent, component} = a_project_with_an_agent()

    # An explicit external id, because `resolve_session/2` looks up by the id the
    # hook injects and the fixture does not set one.
    external = "session-#{System.unique_integer([:positive])}"
    session = session_fixture(scope, external_conversation_id: external)
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, started, _} =
      StartTask.execute(
        %{
          requirement_name: "spec_file",
          entity_type: "component",
          entity_id: component.id,
          session_id: external,
          agent_id: "aqa-1013-4c48b2885a638b42"
        },
        frame
      )

    refute started.isError,
           """
           A sub-agent label was treated as a missing agent and refused.

           Labels are not agent rows and have none to land on, so they keep the
           behaviour they had: the task lives on the caller's session with the
           label as its ownership stamp. Refusing them would break sub-agent
           task assignment entirely.

           Got: #{text(started)}
           """

    {:reply, listed, _} = ListTasks.execute(%{session_id: external}, frame)

    assert text(listed) =~ "spec_file",
           "the task should be on the caller's session, which is where a label's task belongs"
  end
end
