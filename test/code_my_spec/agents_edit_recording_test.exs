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

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.FileEdits
  alias CodeMySpecTest.AgentPresence

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

    AgentPresence.present(agent)

    agent
  end

  defp tool_event(name, path) do
    %{
      "kind" => "tool_start",
      "text" => "#{name} #{path}",
      "tool" => %{"id" => "call_1", "name" => name, "path" => path}
    }
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

    test "a call is recorded as a tool call, with all its arguments" do
      scope = full_scope_fixture()
      agent = running_agent(scope)
      content = String.duplicate("defmodule X do\nend\n", 500)

      event = %{
        "kind" => "tool_start",
        "text" => "write lib/example.ex",
        "tool" => %{
          "id" => "call_1",
          "name" => "write",
          "path" => "lib/example.ex",
          "input" => %{"file_path" => "lib/example.ex", "content" => content}
        }
      }

      :ok = Agents.record_turn_event(scope, agent.id, event)

      assert [message] = messages_for(scope, agent)

      assert [%{"id" => "call_1", "name" => "write", "arguments" => args}] = message.tool_calls,
             "the call was not written into the tool_calls column. Got: #{inspect(message)}"

      assert args["content"] == content,
             "the arguments were cut, and a resumed agent would hold a call it never made"
    end

    test "every result is recorded whole and paired to its call, failed or not" do
      scope = full_scope_fixture()
      agent = running_agent(scope)
      body = String.duplicate("line\n", 2_000)
      read = %{"id" => "call_1", "name" => "read", "path" => "mix.exs", "input" => %{}}
      write = %{"id" => "call_2", "name" => "write", "path" => "lib/x.ex", "input" => %{}}

      for {tool, ending} <- [
            {read, %{"result" => body}},
            {write, %{"result" => "permission denied", "error" => "permission denied"}}
          ] do
        :ok = Agents.record_turn_event(scope, agent.id, %{"kind" => "tool_start", "tool" => tool})

        :ok =
          Agents.record_turn_event(scope, agent.id, %{
            "kind" => "tool_end",
            "tool" => Map.merge(tool, ending)
          })
      end

      assert [read_row, write_row] = Enum.filter(messages_for(scope, agent), &(&1.role == :tool))

      assert {read_row.tool_call_id, Conversations.Message.text(read_row), read_row.tool_failed} ==
               {"call_1", body, false},
             "a successful result was not kept whole, so a resume cannot carry on from it"

      assert {write_row.tool_call_id, write_row.tool_failed} == {"call_2", true}
    end

    test "what the agent said on its way to a call is recorded as its words" do
      scope = full_scope_fixture()
      agent = running_agent(scope)

      :ok =
        Agents.record_turn_event(scope, agent.id, %{
          "kind" => "assistant_message",
          "text" => "Reading the config first."
        })

      assert [message] = messages_for(scope, agent)

      assert {message.role, Conversations.Message.text(message)} ==
               {:assistant, "Reading the config first."}
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
