defmodule CodeMySpec.Hooks.StopNotesTheDecisionTest do
  @moduledoc """
  The stop decision lands on the agent's conversation.

  Story 985, and the commonest case in it: a transcript that changes direction
  between one turn and the next had no explanation in it, and a stop is usually
  what changed it.

  Driven at `decide/2` rather than over HTTP, because that is where both verdicts
  converge and where the scope is in hand. The spex drive the same thing through
  the hook endpoint and read the page; this asserts the record exists at all,
  which is the half that fails silently — a note that is never written and a note
  that is written and never rendered look identical from the transcript.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Hooks.Stop

  setup do
    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)

    copy
    |> Ecto.Changeset.change(root: "/workspace/main", main: true)
    |> Repo.update!()

    scope = %{scope | cwd: "/workspace/main"}

    {:ok, agent} =
      Agents.start_agent(scope, %{
        provider: "anthropic",
        role: "coding",
        engine: :pi,
        working_copy: "/workspace/main"
      })

    %{scope: scope, agent: agent}
  end

  defp orchestrator_messages(agent) do
    case Repo.get_by(Conversation, agent_id: agent.id) do
      nil -> []
      conversation -> conversation |> Conversations.list_messages() |> Enum.filter(&(&1.role == :orchestrator))
    end
  end

  test "a stop decision is written to the agent's thread", %{scope: scope, agent: agent} do
    Stop.decide(scope, %{"session_id" => "a-session-nobody-registered"})

    assert [action] = orchestrator_messages(agent),
           "the hook decided and the conversation says nothing about it. Somebody " <>
             "reading the transcript sees the agent stop and has to go to a log on " <>
             "another machine to find out why."

    assert action.role == :orchestrator,
           "recorded as #{action.role}, which credits the agent with what was done to it."
  end

  test "one decision is one action", %{scope: scope, agent: agent} do
    Stop.decide(scope, %{"session_id" => "a-session-nobody-registered"})

    assert length(orchestrator_messages(agent)) == 1,
           "one stop produced more than one entry. However many analyzers ran, the " <>
             "decision is the thing that happened — a row each is the log rather than " <>
             "the story."
  end

  test "the action names the tool that answers for the detail", %{scope: scope, agent: agent} do
    Stop.decide(scope, %{"session_id" => "a-session-nobody-registered"})

    [action] = orchestrator_messages(agent)

    tool =
      Enum.find_value(action.content, fn
        %{"type" => "tool", "text" => text} -> text
        _ -> nil
      end)

    assert tool == "list_problems",
           "the action summarises with no way to act on it. Half the readers of an " <>
             "agent's transcript are agents, and what an agent can use is the name of a " <>
             "tool rather than a link."
  end

  test "a decision on a project with no agent does not raise", %{scope: scope} do
    other = full_scope_fixture()

    assert %{} = Stop.decide(other, %{"session_id" => "no-agent-here"}),
           "recording broke a verdict for an agent that does not exist. The hook's job " <>
             "is the decision; a note able to break it is worse than no note."

    _ = scope
  end
end
