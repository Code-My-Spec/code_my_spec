defmodule CodeMySpec.Agents.Main.LastCallOfFindsAScriptWrappedCallTest do
  @moduledoc """
  Issue `e832dff8`, criterion 1252 (story 1055) — "a question about a long
  conversation is answered without reading it all".

  Most of this project's tools are reachable only from inside a `run_script`
  body, so a direct-name match on `tool_calls` never sees them: the only
  entry on the turn is named `run_script`, with the real call sitting as text
  inside its `script` argument. `last_call_of` answered "this agent has never
  called `submit_issue_qa_result`" for an agent whose transcript, read
  without the filter, showed exactly that call.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo

  defp put_message(conversation, attrs) do
    %Message{}
    |> Message.agent_changeset(Map.put(attrs, :conversation_id, conversation.id))
    |> Repo.insert!()
  end

  defp an_agent_that_called_a_tool_through_run_script do
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
        role: "qa",
        working_copy_id: copy.id,
        working_copy: "/tmp/script-wrapped-#{System.unique_integer([:positive])}"
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        agent.project_id || scope.active_project_id,
        agent.id
      )

    script =
      "local result, err = submit_issue_qa_result({issue_id = 'f9c8b35c', task_id = 'c598e50c', status = 'partial'})\nreturn result"

    put_message(conversation, %{
      role: :assistant,
      content: [],
      tool_calls: [
        %{"id" => "call_script", "name" => "run_script", "arguments" => %{"script" => script}}
      ]
    })

    put_message(conversation, %{
      role: :tool,
      tool_call_id: "call_script",
      content: [%{"type" => "text", "text" => "SCRIPT-RESULT"}]
    })

    {scope, agent}
  end

  test "a tool called inside a run_script body is found, not reported as never called" do
    {scope, agent} = an_agent_that_called_a_tool_through_run_script()

    {:ok, result} =
      MainAgent.read_agent_conversation(scope, agent.id, last_call_of: "submit_issue_qa_result")

    refute Map.get(result, :no_match),
           """
           The agent called `submit_issue_qa_result` through `run_script`, and
           `last_call_of` reported it as never called.

           Got: #{inspect(result)}
           """

    rendered = Enum.map_join(result.turns, "\n", &MainAgent.turn_line/1)

    assert rendered =~ "run_script" and rendered =~ "submit_issue_qa_result",
           """
           The matching turn (naming the real call inside its script) is missing.

           Got:\n#{rendered}
           """

    assert rendered =~ "SCRIPT-RESULT",
           """
           The run_script call's own result is missing — the caller is left with
           proof the call happened but not what it returned.

           Got:\n#{rendered}
           """
  end

  test "an unrelated tool's run_script call is still reported as never called" do
    {scope, agent} = an_agent_that_called_a_tool_through_run_script()

    {:ok, result} =
      MainAgent.read_agent_conversation(scope, agent.id, last_call_of: "resolve_issue")

    assert result.no_match == {:last_call_of, "resolve_issue"},
           """
           A tool the script never named should still read as never called.

           Got: #{inspect(result)}
           """
  end
end
