defmodule CodeMySpec.Agents.Tools.HandingAnAgentWorkTest do
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

  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.TerminalAgentFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository

  defp text({_status, text}) when is_binary(text), do: text

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end

  defp a_project_with_an_agent do
    scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())
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
      terminal_agent_fixture(scope, %{
        engine_session_id: "sess-#{System.unique_integer([:positive])}"
      })

    frame = %Frame{assigns: %{current_scope: scope}}

    started =
      ToolLibrary.run(
        "start_task",
        %{
          requirement_name: "implementation_file",
          entity_type: "component",
          entity_id: component.id,
          session_id: session.engine_session_id,
          agent_id: agent.id
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, started), text(started)

    # Now ask as the agent would: its own queue, from its own connection.
    agent_frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    listed =
      ToolLibrary.run(
        "list_tasks",
        %{},
        Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
      )

    assert text(listed) =~ "implementation_file",
           """
           The task was started for this agent and is not on its queue.

           This is the whole defect: the assignment reports success, the task
           lands on the caller's session carrying the agent's id, and the agent
           it was for never sees it. An agent told to work something it cannot
           find either does nothing or picks its own work instead.

           Got:\n#{text(listed)}
           """
  end
end
