defmodule CodeMySpec.Agents.Tools.AnAgentWeRunListsSubagentsWithoutASessionIdTest do
  @moduledoc """
  Issue 69808362: `list_session_subagents({})` returned "No session_id and
  no agent id on this call" when called by an agent we run (main or a
  subagent coordinating a handoff), because a harness-run agent's identity
  travels on the connection as the working copy's own harness, not a
  Claude-assigned session id it could pass as a parameter -- and
  `resolve_session/2` only ever looked at the `session_id` param.

  `Sessions.external_id_for_harness/1` already answers "which conversation is
  running in this working copy" for `list_user_questions`, `ask_question`
  and `check_answer`; this is the same join, used the same way.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Sessions

  defp register(session, agent_id, agent_name) do
    {:ok, session} =
      Sessions.register_subagent(%CodeMySpec.Users.Scope{}, session, %{
        agent_id: agent_id,
        agent_name: agent_name,
        last_heartbeat_at: DateTime.utc_now()
      })

    session
  end

  defp text({_status, text}) when is_binary(text), do: text

  defp text(%{content: parts}) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
    end)
  end

  test "a call with no session_id resolves the session running in this working copy" do
    scope = full_scope_fixture()
    {:ok, session} = Sessions.find_or_create_session(scope, "no-session-id-param")
    _session = register(session, "sub-1", "@sub-one")

    frame = %Frame{assigns: %{current_scope: scope}}

    response =
      ToolLibrary.run(
        "list_session_subagents",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    refute text(response) =~ "No session_id and no agent id",
           "an agent with no session_id to supply, but a working copy on scope, should " <>
             "resolve the session running there rather than being told there is nothing " <>
             "to act on. Got: #{text(response)}"

    assert text(response) =~ "sub-1"
  end

  test "no session has ever run in this working copy" do
    scope = full_scope_fixture()

    frame = %Frame{assigns: %{current_scope: scope}}

    response =
      ToolLibrary.run(
        "list_session_subagents",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert text(response) =~ "No session is registered for this working copy"
  end

  test "an explicit session_id still resolves exactly as before" do
    scope = full_scope_fixture()
    {:ok, session} = Sessions.find_or_create_session(scope, "explicit-session-id")
    _session = register(session, "sub-2", "@sub-two")

    frame = %Frame{assigns: %{current_scope: scope}}

    response =
      ToolLibrary.run(
        "list_session_subagents",
        %{session_id: "explicit-session-id"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert text(response) =~ "sub-2"
  end
end
