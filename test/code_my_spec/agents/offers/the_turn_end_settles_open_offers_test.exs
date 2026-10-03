defmodule CodeMySpec.Agents.Offers.TheTurnEndSettlesOpenOffersTest do
  @moduledoc """
  b75b0198 step 1: at turn end each open offer is settled from its kind's
  expectation, read off the agent's tasks and the tool calls on its thread.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.{DevicesFixtures, UsersFixtures}

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Conversations
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  @node "component:c-1:component_spec"

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

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
        continuous: false,
        status: :running,
        working_copy: "/tmp/settle-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    %{scope: scope, agent: agent, conversation: conversation}
  end

  defp offer(ctx, kind, subject) do
    %Offer{} = Offers.record(nil, ctx.agent, kind, subject)
  end

  defp holding(ctx, attrs) do
    {:ok, agent} = Repo.get!(Agent, ctx.agent.id) |> Agent.add_task(attrs) |> Repo.update()
    agent
  end

  defp called(ctx, name, arguments \\ %{}) do
    {:ok, _} =
      Conversations.add_tool_call(
        ctx.conversation,
        Ecto.UUID.generate(),
        name,
        arguments,
        "coding"
      )
  end

  defp end_turn(ctx) do
    {:ok, agent} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)

    {:ok, _} =
      AgentsRepository.update_agent(ctx.scope, agent, %{
        turn_started_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    Agents.record_turn_event(ctx.scope, ctx.agent.id, %{"kind" => "turn_ended"})
  end

  defp settled(%Offer{id: id}), do: Repo.get!(Offer, id)

  describe "a work offer" do
    test "is claimed when start_task took its subject", ctx do
      offered = offer(ctx, :work, {"requirement", @node})

      holding(ctx, %{
        status: :active,
        requirement_name: "component_spec",
        component_id: "c-1",
        started_at: DateTime.utc_now()
      })

      end_turn(ctx)
      assert %{status: :claimed, outcome_at: %DateTime{}} = settled(offered)
    end

    test "is ignored when the turn took nothing", ctx do
      offered = offer(ctx, :work, {"requirement", @node})
      end_turn(ctx)
      assert settled(offered).status == :ignored
    end

    test "is ignored when the turn took other work", ctx do
      offered = offer(ctx, :work, {"requirement", @node})

      holding(ctx, %{
        status: :active,
        requirement_name: "component_spec",
        component_id: "c-2",
        started_at: DateTime.utc_now()
      })

      end_turn(ctx)
      assert settled(offered).status == :ignored
    end

    test "is declined, with the reason, when its task was tapped out", ctx do
      offered = offer(ctx, :work, {"requirement", @node})
      now = DateTime.utc_now()

      holding(ctx, %{
        status: :blocked,
        requirement_name: "component_spec",
        component_id: "c-1",
        started_at: now,
        blocked_at: now,
        blocker_type: :tap_out,
        blocker_id: Ecto.UUID.generate(),
        blocked_reason: "this belongs to another story"
      })

      end_turn(ctx)

      assert %{status: :declined, reason: "this belongs to another story"} = settled(offered)
    end
  end

  describe "a problems offer" do
    test "is claimed when the agent used tools after it", ctx do
      offered = offer(ctx, :problems, {"problem_set", "abc"})
      called(ctx, "edit_file")
      end_turn(ctx)
      assert settled(offered).status == :claimed
    end

    test "is ignored when the only tool calls came before it", ctx do
      called(ctx, "edit_file")
      offered = offer(ctx, :problems, {"problem_set", "abc"})
      end_turn(ctx)
      assert settled(offered).status == :ignored
    end
  end

  test "a resume notice is n_a", ctx do
    offered = offer(ctx, :resume, {"task", "t-1"})
    called(ctx, "start_task")
    end_turn(ctx)
    assert settled(offered).status == :n_a
  end

  # The answer's text is in the delivered message; acting on it is the claim.
  describe "an answer offer" do
    test "is claimed by any tool call after it", ctx do
      offered = offer(ctx, :answer, {"question", "q-1"})
      called(ctx, "read_file")
      end_turn(ctx)
      assert settled(offered).status == :claimed
    end

    test "is ignored when the turn called no tools", ctx do
      offered = offer(ctx, :answer, {"question", "q-1"})
      end_turn(ctx)
      assert settled(offered).status == :ignored
    end

    test "is ignored when the only tool calls came before it", ctx do
      called(ctx, "read_file")
      offered = offer(ctx, :answer, {"question", "q-1"})
      end_turn(ctx)
      assert settled(offered).status == :ignored
    end
  end

  # A resumed task has its blocker cleared and keeps its `started_at`.
  test "an unblocked offer is claimed by resuming a task the blocker held", ctx do
    offered = offer(ctx, :unblocked, {"blocker", "i-1"})

    holding(ctx, %{
      status: :active,
      requirement_name: "story_promoted",
      started_at: DateTime.add(DateTime.utc_now(), -600, :second)
    })

    end_turn(ctx)
    assert settled(offered).status == :claimed
  end

  test "an unblocked offer is ignored while the task stays blocked", ctx do
    offered = offer(ctx, :unblocked, {"blocker", "i-1"})

    holding(ctx, %{
      status: :blocked,
      requirement_name: "story_promoted",
      blocker_type: :issue,
      blocker_id: "i-1"
    })

    end_turn(ctx)
    assert settled(offered).status == :ignored
  end

  test "a check-in is n_a and notes what the turn called", ctx do
    offered = offer(ctx, :check_in, {"cadence", nil})
    called(ctx, "list_agent_work")
    called(ctx, "start_task")
    end_turn(ctx)

    assert %{status: :n_a, note: "called: list_agent_work, start_task"} = settled(offered)
  end

  test "a settled offer is not settled again", ctx do
    offered = offer(ctx, :work, {"requirement", @node})
    end_turn(ctx)
    first = settled(offered)

    holding(ctx, %{
      status: :active,
      requirement_name: "component_spec",
      component_id: "c-1",
      started_at: DateTime.utc_now()
    })

    end_turn(ctx)
    assert settled(offered) == first
  end

  describe "superseding" do
    test "a new offer of the same kind and subject supersedes the open one", ctx do
      first = offer(ctx, :work, {"requirement", @node})
      second = offer(ctx, :work, {"requirement", @node})

      assert %{status: :superseded, outcome_at: %DateTime{}} = settled(first)
      assert %{status: :open, attempt: 2} = settled(second)
    end

    test "a different subject or kind leaves it open", ctx do
      first = offer(ctx, :work, {"requirement", @node})
      offer(ctx, :work, {"requirement", "component:c-2:component_spec"})
      offer(ctx, :problems, {"requirement", @node})

      assert settled(first).status == :open
    end

    test "the attempt count starts over after a claim", ctx do
      offer(ctx, :problems, {"problem_set", "abc"})
      called(ctx, "edit_file")
      end_turn(ctx)

      assert %{attempt: 1} = offer(ctx, :problems, {"problem_set", "abc"})
    end
  end
end
