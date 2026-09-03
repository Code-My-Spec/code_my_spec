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
  alias CodeMySpec.FileEdits

  defp running_agent(scope) do
    {:ok, agent} =
      CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
        engine: :pi,
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

  test "one agent's write is not recorded against another" do
    scope = full_scope_fixture()
    editor = running_agent(scope)
    bystander = running_agent(scope)

    :ok = Agents.record_turn_event(scope, editor.id, tool_event("write", "lib/example.ex"))

    assert FileEdits.get_edited_files_for_agent(bystander.id) == [],
           "attribution leaked between two agents sharing a working copy"
  end
end
