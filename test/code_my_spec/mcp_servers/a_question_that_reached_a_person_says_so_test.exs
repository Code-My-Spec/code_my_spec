defmodule CodeMySpec.McpServers.AQuestionThatReachedAPersonSaysSoTest do
  @moduledoc """
  Asking a person is told apart from asking the main agent, at the moment of
  asking.

  Issue `08d4d7bd`. A question has no dismiss and no expiry — deliberately, and
  story 896 argues it well: one vanishing on a clock is a decision the user never
  made. The cost falls on anybody who asks one by accident, and it has fallen
  twice. A QA agent exercising the ask→answer round trip called its own typed
  tool from a worktree of the real project, so the tool was bound to the real dev
  harness, and two "please ignore" probes are permanent clutter in the owner's
  inbox that only they can clear.

  A typed tool cannot be pointed at another harness, so nothing about the call
  could have gone differently. What was missing is that the caller had no way to
  know, at the moment of asking, that this one was real.

  Only when the holder is the person. An agent's question routed to the main
  agent is ordinary traffic, and a warning on every ask is one worth ignoring —
  which is the failure mode this is trying to avoid, not repeat.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion

  defp text(response) do
    response |> Response.to_protocol() |> Map.get("content") |> hd() |> Map.get("text")
  end

  defp ask(frame) do
    {:reply, response, _frame} =
      AskUserQuestion.execute(
        %{
          title: "A question",
          questions: [%{"question" => "Which way?", "options" => ["left", "right"]}]
        },
        frame
      )

    text(response)
  end

  defp an_agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        working_copy: "/tmp/asking-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  setup do
    %{scope: full_scope_fixture()}
  end

  test "a question a person holds says it cannot be taken back", %{scope: scope} do
    said = ask(%Frame{assigns: %{current_scope: scope}})

    assert said =~ "waiting on a person"

    assert said =~ "cannot be withdrawn", """
    The caller is told a question id and nothing else. Somebody exercising the
    ask path finds out what they did when the owner asks about it — which is how
    two "please ignore" probes ended up permanent (08d4d7bd).
    """

    assert said =~ "sandbox",
           "saying it is permanent without saying what to do instead is half a warning"
  end

  test "a question the main agent holds does not", %{scope: scope} do
    coding = an_agent(scope, "coding")

    said = ask(%Frame{assigns: %{current_scope: scope, agent_id: coding.id}})

    refute said =~ "waiting on a person", """
    Said on every ask, this is a sentence every caller learns to skip — and then
    it is not there when it matters. An agent's question routed to the main
    agent is ordinary traffic.
    """
  end

  test "and the main agent's own question does, because that one reaches a person", %{
    scope: scope
  } do
    main = an_agent(scope, "main")

    said = ask(%Frame{assigns: %{current_scope: scope, agent_id: main.id}})

    assert said =~ "waiting on a person", """
    The main agent has nobody above it to route to, so its questions go straight
    to the person and are exactly as permanent as a session's.
    """
  end
end
