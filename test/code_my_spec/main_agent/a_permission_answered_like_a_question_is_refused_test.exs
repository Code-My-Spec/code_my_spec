defmodule CodeMySpec.Agents.Main.APermissionAnsweredLikeAQuestionIsRefusedTest do
  @moduledoc """
  `list_notifications` unions questions and permissions on purpose — both stop
  an agent identically — so reaching for the wrong verb on one of them is an
  ordinary mistake, and it crashed.

  `fetch_open_question/2` reads that same union, so it finds a `tap_out` and
  hands it over as though it were a question. Everything after treats it as
  one, and the first thing to need an actual question row is
  `escalate_question/3` inside `weigh/4`: it looks the id up among
  `QuestionRequest`s, finds nothing, and raises

      expected a map, got: nil

  — a `BadMapError` several layers below a caller who asked a perfectly
  ordinary thing, naming neither the id nor the verb that would have worked.

  Measured 2026-09-17 while granting two QA agents' tap-outs. An *unknown* id
  refused cleanly and a permission id crashed, which is exactly the wrong way
  round: the caller who could have acted on the answer is the one who got
  nothing.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Notifications
  alias CodeMySpecTest.AgentPresence

  setup do
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
        working_copy: "/tmp/permission-#{System.unique_integer([:positive])}",
        status: :running
      })

    AgentPresence.present(agent)

    {:ok, permission} =
      Notifications.create_permission_request(scope.user.id, %{
        "agent_id" => agent.id,
        "tool_name" => "tap_out",
        "tool_input" => %{}
      })

    %{scope: scope, permission: permission}
  end

  test "answering a permission with prose refuses and names the verb", ctx do
    result =
      MainAgent.answer_question(ctx.scope, ctx.permission.id, "go ahead", basis: "record")

    assert {:error, :is_permission} = result, """
    A permission id went down the question path.

    Either it crashed — `expected a map, got: nil`, from `escalate_question/3`
    looking for a question row that was never there — or it was answered as a
    question, which records prose against something that only takes `allow` or
    `deny` and leaves the agent still gated.

    Got: #{inspect(result)}
    """
  end

  test "an id that is neither still reads as not found", ctx do
    assert {:error, :not_found} =
             MainAgent.answer_question(ctx.scope, Ecto.UUID.generate(), "x", basis: "record"),
           """
           The unknown-id refusal moved while the permission one was being fixed.

           These two have to stay distinguishable: "no such notification" and
           "wrong verb for this one" send the caller to different places, and
           collapsing them is how the permission case became a crash in the
           first place.
           """
  end
end
