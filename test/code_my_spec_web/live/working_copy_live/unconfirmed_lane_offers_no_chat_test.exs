defmodule CodeMySpecWeb.WorkingCopyLive.UnconfirmedLaneOffersNoChatTest do
  @moduledoc """
  A chat is offered where a message can actually be delivered, and nowhere else.

  ## What this used to assert, and why it changed

  It asserted that a lane at `:starting` is never offered a chat. Issue
  90930fca, and the argument was right: `HarnessChannel` pushed an operator
  message to whatever was joined on the topic, so with nothing joined the text
  was written to the conversation and reached nobody. A box that accepts text
  and drops it is worse than no box — the person believes they redirected an
  agent and finds out when the work comes back wrong. Criterion 2834 makes the
  same argument for Claude Code.

  Two things have moved underneath it.

  The send is no longer that push. `AgentConversationLive.Show`'s
  `send_message` dispatches through `Agents.dispatch_message/3` — the transport,
  addressed by working copy — and it refuses rather than absorbing, answering
  `{:error, :not_running}`. Once failure is reported, the silent drop this test
  was written against cannot happen on this path, and withholding the box buys
  nothing.

  Criterion 2896 makes that the requirement rather than a permission: an agent
  whose machine cannot be reached must still get a send box, *because* the
  criterion is that the failure is reported — and a missing box cannot report
  anything. It looks like there was never an agent. So a connection check here
  would fail the story one criterion over.

  And `:running`, the thing this test set up as absent, turned out to be
  unreachable in general. A row only leaves `:starting` through
  `record_reported/2`, driven by `LaneReporter`, which the light harness never
  starts (`CmsHarness.Supervisor` alone: no Presence, no SocketSupervisor, no
  reporter). On such a machine no row ever becomes `:running`, so gating on it
  hid every working agent. The war-epic product agent answered a real turn while
  its row said `:starting` and this page offered no chat at all.

  What is left is one fact: a thread with an agent nobody has stopped.
  """

  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpecSpex.WorkingCopyHelpers
  import Phoenix.LiveViewTest

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Agents.AgentsRepository
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # What `Agents.start_agent/2` leaves behind: a row asking for a lane, which
  # only `record_reported/2` ever moves to :running. Written directly rather than
  # through `report_agents/2`, because that helper reports *as a harness would*
  # and a harness reporting it is exactly what has not happened.
  defp requested_pi_lane(context, root) do
    copy = join_working_copy(context, root, "a copy with an unconfirmed lane")

    {:ok, agent} =
      AgentsRepository.create_agent(context.scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: root,
        role: "coding",
        working_copy_id: copy.working_copy_id,
        project_id: context.scope.active_project_id,
        account_id: context.scope.active_account_id,
        status: :starting
      })

    # The lane needs a conversation or it never reaches `chattable?/1` at all —
    # `chats` would be empty and the page would withhold the chat for the wrong
    # reason, which is a test that passes on the bug.
    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        context.scope.active_account_id,
        context.scope.active_project_id,
        agent.id
      )

    {copy, agent}
  end

  defp show(context, copy) do
    {:ok, live, _html} =
      live(
        context.conn,
        "/app/projects/#{context.scope.active_project_id}/working-copies/#{copy.working_copy_id}"
      )

    live
  end

  test "a lane awaiting confirmation on a connected harness is offered a chat", context do
    {copy, _agent} = requested_pi_lane(context, "/tmp/unconfirmed-lane")
    live = show(context, copy)

    assert has_element?(live, "[data-test='open-agent-chat']"),
           "the page withheld the chat from an agent that has a thread and has not " <>
             "been stopped. `:starting` is not evidence of absence — on a light " <>
             "harness nothing ever moves a row off it, so gating here hides every " <>
             "working agent. Delivery refuses honestly if the lane has gone."
  end

  test "a copy whose agent was stopped is offered no chat, and the page says why", context do
    {copy, agent} = requested_pi_lane(context, "/tmp/unconfirmed-lane-gone")

    # The one status that is evidence rather than inference: somebody asked for
    # this agent to stop and it did. There is nothing to say anything to, and
    # unlike an unreachable machine it is not coming back on its own.
    {:ok, _} = AgentsRepository.update_agent(context.scope, agent, %{status: :stopped})

    live = show(context, copy)

    refute has_element?(live, "[data-test='open-agent-chat']"),
           "a box that accepts text and drops it is worse than no box"

    assert has_element?(live, "[data-test='no-agent-chat']"),
           "withholding the chat without saying why reads as the page being broken " <>
             "rather than as a decision."
  end

  test "the reason names this copy rather than agents in general", context do
    {copy, agent} = requested_pi_lane(context, "/tmp/unconfirmed-lane-reason")
    {:ok, _} = AgentsRepository.update_agent(context.scope, agent, %{status: :stopped})

    html =
      context
      |> show(copy)
      |> element("[data-test='no-agent-chat']")
      |> render()

    # The original asserted "has not confirmed", which named a wait that never
    # ended on a light harness — nothing reports, so the chat it promised would
    # open never did. What is left has to be true of this copy.
    refute html =~ "has not confirmed",
           "the page still promises the chat opens once the harness reports, and on " <>
             "this deployment nothing ever reports. Got: #{html}"

    assert html =~ "lane" or html =~ "copy",
           "the reason says nothing about this checkout. Got: #{html}"
  end
end
