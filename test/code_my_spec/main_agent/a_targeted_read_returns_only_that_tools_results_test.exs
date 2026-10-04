defmodule CodeMySpec.Agents.Main.ATargetedReadReturnsOnlyThatToolsResultsTest do
  @moduledoc """
  Issue `ec56b436`, criterion 3282 — "answered without reading it all".

  `read_agent_conversation(last_call_of: tool)` exists so a caller can ask "when
  did it last call this, and what came back" without pulling a transcript it
  cannot afford to read. `results_for/2` mapped over *every* id in the matching
  turn's `tool_calls`, so a turn that batched several different calls returned
  all of their results.

  Found by QA against agent `880c7713`: asking for `list_problems` came back
  with `list_tasks`, `list_issues`, a Lua error and a timeout mixed in. The
  caller then has to read and discard the noise it asked not to be sent, and —
  worse — can attribute another tool's error to the one it asked about.

  It survived because the common case hides it. A turn with a single tool call
  has a single id, and filtering by name is a no-op there; every earlier test
  and every manual check had been on single-call turns. This one batches three,
  which is the only shape that can tell the two implementations apart.

  The assistant turn itself is still returned whole — it is the record of what
  the agent did, and narrowing its `tool_calls` would be editing history. The
  leak was in the results hung off it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Repo

  defp put_message(conversation, attrs) do
    %Message{}
    |> Message.agent_changeset(Map.put(attrs, :conversation_id, conversation.id))
    |> Repo.insert!()
  end

  # One turn that called three different tools, followed by each of their
  # results. This is the shape `last_call_of` has to narrow.
  defp an_agent_whose_turn_batched_three_calls do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy_id: copy.id,
        working_copy: "/tmp/batched-#{System.unique_integer([:positive])}"
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        agent.project_id || scope.active_project_id,
        agent.id
      )

    put_message(conversation, %{
      role: :assistant,
      content: [],
      tool_calls: [
        %{"id" => "call_problems", "name" => "list_problems", "arguments" => %{}},
        %{"id" => "call_tasks", "name" => "list_tasks", "arguments" => %{}},
        %{"id" => "call_issues", "name" => "list_issues", "arguments" => %{}}
      ]
    })

    put_message(conversation, %{
      role: :tool,
      tool_call_id: "call_problems",
      content: [%{"type" => "text", "text" => "PROBLEMS-RESULT"}]
    })

    put_message(conversation, %{
      role: :tool,
      tool_call_id: "call_tasks",
      content: [%{"type" => "text", "text" => "TASKS-RESULT"}]
    })

    put_message(conversation, %{
      role: :tool,
      tool_call_id: "call_issues",
      tool_failed: true,
      content: [%{"type" => "text", "text" => "ISSUES-LUA-ERROR"}]
    })

    {scope, agent}
  end

  test "asking for one tool does not return the other calls' results" do
    {scope, agent} = an_agent_whose_turn_batched_three_calls()

    {:ok, %{turns: turns}} =
      MainAgent.read_agent_conversation(scope, agent.id, last_call_of: "list_problems")

    rendered = Enum.map_join(turns, "\n", &MainAgent.turn_line/1)

    assert rendered =~ "PROBLEMS-RESULT",
           """
           The result of the tool that was actually asked about is missing, which
           is the whole point of the call.

           Got:\n#{rendered}
           """

    refute rendered =~ "TASKS-RESULT",
           """
           A targeted read returned another tool's result.

           The caller asked "when did it last call `list_problems` and what came
           back" precisely so it would not have to read the rest. Sending the
           rest makes it read and discard exactly what it asked to avoid.

           Got:\n#{rendered}
           """

    refute rendered =~ "ISSUES-LUA-ERROR",
           """
           An unrelated tool's *failure* was returned under a question about a
           different tool.

           This is the costly half. A caller asking about `list_problems` and
           handed a Lua error from `list_issues` in the same answer will
           reasonably attribute the error to `list_problems`, and go and
           investigate a tool that worked.

           Got:\n#{rendered}
           """
  end
end
