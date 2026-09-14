defmodule CodeMySpecTest.GraphHelpersTest do
  @moduledoc """
  The helpers are only worth having if their *failures* are trustworthy.

  `refute_woken/2` is the assertion most of the agent stories lean on — role
  scoping is the claim that a coding agent is told about coding work and a QA
  agent is not. An assertion that passes because nothing happened at all would
  make every one of those stories pass while testing nothing, which is exactly
  the failure it exists to catch.

  So these tests exercise the negative path against a genuinely woken agent,
  not just against silence.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpecTest.GraphHelpers

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues

  setup do
    context = %{scope: full_scope_fixture()}
    context = install_recording_transport(context)

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(context.scope, nil,
        label: "a checkout",
        device: device_fixture(context.scope)
      )

    Map.put(context, :copy, copy)
  end

  defp agent_with_role(scope, copy, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: true,
        working_copy: "/tmp/gh-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, _} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    agent
  end

  test "an issue reaches the role that triages it", context do
    product = agent_with_role(context.scope, context.copy, "product")
    context = watch_graph(context)

    {:ok, _} =
      Issues.create_issue(context.scope, %{
        title: "something is wrong",
        description: "filed while product was idle",
        severity: :medium
      })

    settle_graph(context)

    assert_woken(product.id)
  end

  test "the graph announces on the project topic", context do
    context = watch_graph(context)

    {:ok, _} =
      Issues.create_issue(context.scope, %{
        title: "another",
        description: "d",
        severity: :low
      })

    settle_graph(context)

    assert_graph_announced(context)
  end

  test "refute_woken fails when the agent really was woken", context do
    product = agent_with_role(context.scope, context.copy, "product")
    context = watch_graph(context)

    {:ok, _} =
      Issues.create_issue(context.scope, %{
        title: "wakes product",
        description: "d",
        severity: :medium
      })

    settle_graph(context)

    assert_raise ExUnit.AssertionError, fn -> refute_woken(product.id) end
  end

  test "assert_woken fails, and says why, when nothing was woken at all", context do
    _ = watch_graph(context)

    # An id nothing could have delivered to, because the subject here is the
    # failure *message* and a real agent is no longer reliably un-woken: the
    # watcher computes on arrival and wakes whatever that first pass makes
    # actionable, which for a product agent on a fresh project is the normal
    # case rather than an edge one.
    error = assert_raise ExUnit.AssertionError, fn -> assert_woken(Ecto.UUID.generate()) end

    assert error.message =~ "was not woken",
           "The failure should say the agent was not woken."

    assert error.message =~ "watch_graph",
           """
           The failure should name the forgotten-watcher possibility. `settle/1`
           answers :ok when nothing is watching, so a missing watcher looks
           exactly like correct role scoping — the failure message is the only
           place that distinction gets made.
           """
  end

  test "refute_graph_announced passes when nothing touched a graph input", context do
    context = watch_graph(context)
    settle_graph(context)
    refute_graph_announced(context)
  end
end
