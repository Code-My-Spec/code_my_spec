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

  ## Why a fully-satisfied project

  Because "a genuinely woken agent" got harder to produce, in the way that
  matters. A pass wakes for work that *appeared* — the difference between its
  actionable set and the previous pass's — so a bare fixture project cannot
  produce one at all: `personas_complete` is actionable from the first pass and
  stays actionable, and every requirement that could newly appear is blocked
  behind the serial chain.

  Filing an issue on a bare project used to look like a wake and was one, with
  the wrong cause: the old rule woke on any actionable work after a non-first
  pass, and `personas_complete` was always there. Green either way, which is the
  property that makes a helper test worthless.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecTest.GraphHelpers

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    {:ok, install_recording_transport(context)}
  end

  defp agent_with_role(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: true,
        working_copy: scope.cwd,
        working_copy_id: scope.active_working_copy_id
      })

    {:ok, _} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    agent
  end

  # A project with nothing left to do, so the next thing that becomes
  # actionable is unambiguously the thing this test did.
  defp quiet_project(context) do
    context = FullSatisfactionFixtures.apply(context)
    context = watch_graph(context)
    settle_graph(context)
    context
  end

  defp file_an_issue(context) do
    {:ok, _} =
      Issues.create_issue(context.scope, %{
        title: "something is wrong",
        description: "filed while product was idle",
        severity: :medium
      })

    settle_graph(context)
  end

  test "an issue reaches the role that triages it", context do
    context = quiet_project(context)
    product = agent_with_role(context.scope, "product")

    file_an_issue(context)

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
    context = quiet_project(context)
    product = agent_with_role(context.scope, "product")

    file_an_issue(context)

    assert_raise ExUnit.AssertionError, fn -> refute_woken(product.id) end
  end

  test "assert_woken fails, and says why, when nothing was woken at all", context do
    _ = watch_graph(context)

    # An id nothing could have delivered to, because the subject here is the
    # failure *message* rather than the routing.
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
