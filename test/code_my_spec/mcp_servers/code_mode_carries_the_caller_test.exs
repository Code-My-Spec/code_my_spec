defmodule CodeMySpec.McpServers.CodeModeCarriesTheCallerTest do
  @moduledoc """
  A script's tool calls act for whoever sent the script.

  Issue `1a892606`. `invoker/2` built a fresh frame holding only the scope and
  passed the script's arguments through untouched, so neither carrier of the
  caller's identity survived: an agent we run is known by its connection, and a
  Claude Code session is known by a `session_id` the `PreToolUse` hook injects
  into the tool's input. Every task tool therefore refused from inside a script
  — `list_tasks`, `evaluate_task`, `start_task`, `cancel_task`, `assign_task` —
  so a caller could script everything except claiming or finishing work.

  What made it cost a session rather than a minute: the refusal said to call
  `register_session`, a caller did, was told it had worked, and got the identical
  refusal from the next line of the same script. Registering creates the session;
  it was never what carried the id. So the assertions here are about the *absence
  of the refusal*, which is the thing the advice could not produce.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpec.Sessions

  @no_owner "there is no owner whose"

  defp text(response) do
    response |> Response.to_protocol() |> Map.get("content") |> hd() |> Map.get("text")
  end

  defp run(script, params, frame) do
    {:reply, response, _frame} =
      RunScript.execute(Map.merge(%{script: script}, params), frame)

    text(response)
  end

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  describe "a Claude Code session" do
    test "reaches its own tasks from inside a script", %{scope: scope, frame: frame} do
      external_id = "session_#{System.unique_integer([:positive])}"
      {:ok, _session} = Sessions.find_or_create_session(scope, external_id)

      answer = run("return list_tasks({})", %{session_id: external_id}, frame)

      refute answer =~ @no_owner, """
      The session id reached run_script and did not reach the tool it called, which
      is the whole of 1a892606. Answer was:

      #{answer}
      """

      assert answer =~ "No tasks on this session."
    end

    test "and is refused, still, when nothing said who is asking", %{frame: frame} do
      answer = run("return list_tasks({})", %{}, frame)

      assert answer =~ @no_owner,
             "a script with no caller identity resolved an owner from somewhere, " <>
               "which is worse than the refusal — it would be somebody else's"
    end

    test "never has its explicit choice overridden", %{scope: scope, frame: frame} do
      mine = "session_#{System.unique_integer([:positive])}"
      {:ok, _} = Sessions.find_or_create_session(scope, mine)

      # The script names a session that does not exist. The injected id must not
      # quietly stand in for it: substituting a different owner for the one the
      # caller named is the same class of bug as answering the oldest pending
      # question instead of the named one.
      script = ~S|return list_tasks({ session_id = "not-a-session" })|

      answer = run(script, %{session_id: mine}, frame)

      assert answer =~ "Session not found: not-a-session"
    end
  end

  describe "an agent we run" do
    test "reaches its own tasks from inside a script", %{scope: scope} do
      {:ok, agent} =
        AgentsRepository.create_agent(scope, %{
          provider: "anthropic",
          engine: :alloy,
          role: "coding",
          working_copy: "/tmp/code-mode-caller-#{System.unique_integer([:positive])}",
          working_copy_id: scope.active_working_copy_id
        })

      # Its id is on the connection, not in the call — which is exactly why the
      # fresh inner frame lost it.
      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      answer = run("return list_tasks({})", %{}, frame)

      refute answer =~ @no_owner, """
      An agent we run could not see its own tasks from inside a script. On
      2026-09-07 one in this state asked a person for a session id while seven
      completed tasks sat on its own row. Answer was:

      #{answer}
      """
    end
  end
end
