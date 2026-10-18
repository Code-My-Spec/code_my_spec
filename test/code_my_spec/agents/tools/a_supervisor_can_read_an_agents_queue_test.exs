defmodule CodeMySpec.Agents.Tools.ASupervisorCanReadAnAgentsQueueTest do
  @moduledoc """
  `list_tasks` answers about a named agent, not only about whoever called it.

  `resolve_owner/3` read `frame.assigns[:agent_id]` — the caller's own identity —
  and the tool's params were `session_id` and `status`. So the main agent asking
  "what is that agent holding" got its own session's tasks instead, with no way
  to ask otherwise, while the tool's moduledoc has always said it exists "so the
  main agent can track subagent progress".

  Measured before the fix, supervising a live QA agent: its stop menu told it
  "you have 4 open tasks, most recently `qa_complete` on story 895 ... call
  `evaluate_task` with task_id 6735cdc7", and the main agent's `list_tasks`
  returned 277 rows of its own session with no `6735cdc7` among them. Supervisor
  and supervised disagreed about which tasks existed and neither could see the
  other's view — so "idle because finished" and "idle holding four unevaluated
  tasks" were the same observation from outside.

  `start_task` already took `agent_id` and used the identical `resolve_owner`
  shape, which is how a task gets onto an agent in the first place. This makes
  the reading half match the writing half.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository

  defp response_text({_status, text}) when is_binary(text), do: text

  defp response_text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end

  defp a_project_with_an_agent_holding_a_task do
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
        working_copy: "/tmp/queue-#{System.unique_integer([:positive])}"
      })

    # The graph has to hold the requirement before a task can start on it.
    CodeMySpec.Requirements.recompute(scope)

    # Started *as the agent*. `StartTask` resolves where a task lands from the
    # caller (`frame.assigns[:agent_id]`); its `agent_id` param only stamps
    # ownership. So a task on the agent-s own record is one the agent started,
    # which is the population a supervisor needs to read.
    agent_frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
    frame = %Frame{assigns: %{current_scope: scope}}

    started =
      ToolLibrary.run(
        "start_task",
        %{
          requirement_name: "implementation_file",
          entity_type: "component",
          entity_id: component.id
        },
        Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, started),
           "the premise is an agent holding a task: #{response_text(started)}"

    {scope, agent, frame}
  end

  test "a supervisor reads a named agent's queue" do
    {_scope, agent, frame} = a_project_with_an_agent_holding_a_task()

    # No `agent_id` on the frame — this is the main agent's position, asking
    # about somebody else.
    response =
      ToolLibrary.run(
        "list_tasks",
        %{agent_id: agent.id},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response), response_text(response)
    text = response_text(response)

    assert text =~ "implementation_file",
           """
           Asking about a named agent did not return that agent's work.

           This is the whole of supervising. Without it the main agent cannot
           tell an agent that has finished from one sitting on unevaluated
           tasks, because both look like "idle" from outside.

           Got:\n#{text}
           """

    # Deliberately not asserting the row repeats the agent id. A task on an
    # agent's own record is already that agent's; `task.agent_id` is the
    # ownership stamp `start_task` applies when somebody claims a task on a
    # *session*, and it is legitimately nil here.
  end

  test "asking about an agent on another project finds nothing rather than crossing over" do
    {_scope, _agent, _frame} = a_project_with_an_agent_holding_a_task()

    # A second project, whose scope has no business seeing the first one's agent.
    other = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())
    other_frame = %Frame{assigns: %{current_scope: other}}

    response =
      ToolLibrary.run(
        "list_tasks",
        %{agent_id: Ecto.UUID.generate()},
        Map.put(other_frame.assigns, :scope, other_frame.assigns[:current_scope])
      )

    assert match?({:error, _}, response),
           """
           An agent id that does not belong to this scope was answered rather
           than refused.

           `Agents.fetch_agent/2` is scope-guarded and that guard is what keeps
           this from becoming a way to read another project's fleet. A silent
           empty list would be worse than an error: it reads as "that agent has
           no work".
           """
  end

  # 8c1e192c: `run_script` handed every list tool's rendered text straight to
  # Lua, so a script iterating it with `ipairs` got "table expected, got
  # string" instead of rows.
  test "script_result returns task rows as data rather than rendered text" do
    {_scope, agent, frame} = a_project_with_an_agent_holding_a_task()

    assert {:ok, [row]} =
             ToolLibrary.data(
               "list_tasks",
               %{agent_id: agent.id},
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    assert row["requirement_name"] == "implementation_file"
  end

  test "an agent asking with no argument still gets its own" do
    {scope, agent, _frame} = a_project_with_an_agent_holding_a_task()
    agent_frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    response =
      ToolLibrary.run(
        "list_tasks",
        %{},
        Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response),
           """
           Adding the `agent_id` route broke the ordinary one.

           Every agent calling `list_tasks` with no argument means "what am I
           holding", and that has to keep working — it is how an agent finds the
           task ids its stop menu tells it to evaluate.

           Got: #{response_text(response)}
           """

    assert response_text(response) =~ "implementation_file",
           "the agent's own call has to return its own work, not an empty list"
  end
end
