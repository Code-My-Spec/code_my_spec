defmodule CodeMySpec.AgentsEditRecordingTest do
  @moduledoc """
  The producing half of edit tracking: a tool call arriving from the harness
  becomes a recorded edit.

  Written because the consuming half was already covered and that proved less
  than it looked. `InternalAgentOwnsItsTreeTest` calls
  `FileEdits.track_agent_edit/2` itself, so it stays green with the recording in
  `record_turn_event/3` disabled entirely — a probe placed where it cannot fail.
  These assert the path that actually runs in production: envelope in, row out.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.FileEdits

  defp running_agent(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        role: "coding",
        status: :running,
        working_copy: scope.cwd || "/tmp/a-copy",
        working_copy_id: scope.active_working_copy_id,
        tools: []
      })

    agent
  end

  defp tool_event(name, path) do
    %{"kind" => "tool_start", "text" => "#{name} #{path}", "tool" => %{"id" => "call_1", "name" => name, "path" => path}}
  end

  test "a write call is recorded against the agent" do
    scope = full_scope_fixture()
    agent = running_agent(scope)

    :ok = Agents.record_turn_event(scope, agent.id, tool_event("write", "lib/example.ex"))

    assert FileEdits.get_edited_files_for_agent(agent.id) == ["lib/example.ex"],
           "a write the agent made was not recorded, so nothing can be attributed to it"
  end

  test "an edit call is recorded too" do
    scope = full_scope_fixture()
    agent = running_agent(scope)

    :ok = Agents.record_turn_event(scope, agent.id, tool_event("edit", "lib/changed.ex"))

    assert FileEdits.get_edited_files_for_agent(agent.id) == ["lib/changed.ex"]
  end

  test "reading a file is not editing it" do
    scope = full_scope_fixture()
    agent = running_agent(scope)

    :ok = Agents.record_turn_event(scope, agent.id, tool_event("read", "lib/example.ex"))

    assert FileEdits.get_edited_files_for_agent(agent.id) == [], """
    Reading was recorded as an edit. `read`, `bash` and the script tools all
    name paths, and recording those would make an agent answerable for every
    file it has ever looked at — which is the whole-tree behaviour this
    replaced.
    """
  end

  test "a tool call naming no path records nothing" do
    scope = full_scope_fixture()
    agent = running_agent(scope)

    :ok =
      Agents.record_turn_event(scope, agent.id, %{
        "kind" => "tool_start",
        "tool" => %{"id" => "call_1", "name" => "write", "path" => nil}
      })

    assert FileEdits.get_edited_files_for_agent(agent.id) == []
  end

  test "the same file written twice is recorded once" do
    scope = full_scope_fixture()
    agent = running_agent(scope)

    :ok = Agents.record_turn_event(scope, agent.id, tool_event("write", "lib/example.ex"))
    :ok = Agents.record_turn_event(scope, agent.id, tool_event("write", "lib/example.ex"))

    assert FileEdits.get_edited_files_for_agent(agent.id) == ["lib/example.ex"],
           "an agent editing one file repeatedly must not grow its ledger without bound"
  end

  describe "the transcript" do
    alias CodeMySpec.Conversations

    defp messages_for(scope, agent) do
      {:ok, conversation} =
        Conversations.find_or_create_agent_conversation(
          scope.active_account_id,
          scope.active_project_id,
          agent.id
        )

      Conversations.list_messages(conversation)
    end

    test "a call is recorded as a tool call, with its arguments" do
      scope = full_scope_fixture()
      agent = running_agent(scope)

      event = %{
        "kind" => "tool_start",
        "text" => "write lib/example.ex",
        "tool" => %{
          "id" => "call_1",
          "name" => "write",
          "path" => "lib/example.ex",
          "input" => %{"file_path" => "lib/example.ex", "content" => "defmodule X do\nend\n"}
        }
      }

      :ok = Agents.record_turn_event(scope, agent.id, event)

      assert [message] = messages_for(scope, agent)

      assert [%{"id" => "call_1", "name" => "write", "arguments" => args}] = message.tool_calls,
             """
             The call was written as prose rather than into the tool_calls
             column, so the conversation view renders it as a chat message —
             which is what it did for every internal agent. Got: #{inspect(message)}
             """

      assert args["file_path"] == "lib/example.ex",
             "the arguments were dropped, which is most of what the call was"
    end

    test "a successful call is one row, not two" do
      scope = full_scope_fixture()
      agent = running_agent(scope)

      tool = %{"id" => "call_1", "name" => "read", "path" => "mix.exs", "input" => %{}}

      :ok = Agents.record_turn_event(scope, agent.id, %{"kind" => "tool_start", "tool" => tool})
      :ok = Agents.record_turn_event(scope, agent.id, %{"kind" => "tool_end", "tool" => tool})

      assert length(messages_for(scope, agent)) == 1, """
      Both ends of one call were recorded, which is why every call appeared
      twice in the transcript. `tool_end` carries no result text, so a success
      has nothing to say the call did not.
      """
    end

    test "a failed call records why, paired to the call" do
      scope = full_scope_fixture()
      agent = running_agent(scope)

      tool = %{"id" => "call_9", "name" => "write", "path" => "lib/x.ex", "input" => %{}}

      :ok = Agents.record_turn_event(scope, agent.id, %{"kind" => "tool_start", "tool" => tool})

      :ok =
        Agents.record_turn_event(scope, agent.id, %{
          "kind" => "tool_end",
          "tool" => Map.put(tool, "error", "permission denied")
        })

      messages = messages_for(scope, agent)

      assert result = Enum.find(messages, &(&1.role == :tool))
      assert result.tool_call_id == "call_9", "the failure was not paired to its call"
      assert result.tool_failed == true
    end
  end

  test "one agent's write is not recorded against another" do
    scope = full_scope_fixture()
    editor = running_agent(scope)
    bystander = running_agent(scope)

    :ok = Agents.record_turn_event(scope, editor.id, tool_event("write", "lib/example.ex"))

    assert FileEdits.get_edited_files_for_agent(bystander.id) == [],
           "attribution leaked between two agents sharing a working copy"
  end
end
