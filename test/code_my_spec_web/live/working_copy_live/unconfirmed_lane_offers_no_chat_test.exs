defmodule CodeMySpecWeb.WorkingCopyLive.UnconfirmedLaneOffersNoChatTest do
  @moduledoc """
  A Pi lane nobody has confirmed is not offered a chat.

  Issue 90930fca, whose own first line is the point: "Same class of bug as
  fcd8f7ba, one function over, and it survived that fix." `Liveness` was taught
  that `:starting` is a request rather than a report, and `chattable?/1` one
  panel further down the page was still gating on engine alone — so the page said
  "no harness has confirmed it" and then offered to message it.

  `HarnessChannel` pushes an operator message to whatever is joined on the topic,
  and nothing is joined. The message is written to the conversation and reaches
  nobody, which the Show moduledoc already argues against for the Claude Code
  case: a box that accepts text and drops it is worse than no box, because the
  person believes they redirected an agent and finds out when the work comes back
  wrong.

  Criterion 2834 covers that argument for Claude Code. Nothing covered it for a
  Pi lane that has not come up, which is how the same mistake got a second
  panel.
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
        engine: :pi,
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

  test "no chat is offered, and the page says why", context do
    {copy, _agent} = requested_pi_lane(context, "/tmp/unconfirmed-lane")
    live = show(context, copy)

    refute has_element?(live, "[data-test='open-agent-chat']"),
           "the page offered a chat to a lane no harness has confirmed. The channel " <>
             "pushes to whatever is joined on the topic and nothing is joined, so the " <>
             "message is written and reaches nobody — the failure the Show moduledoc " <>
             "already refuses to ship for Claude Code."

    assert has_element?(live, "[data-test='no-agent-chat']"),
           "withholding the chat without saying why reads as the page being broken " <>
             "rather than as a decision."
  end

  test "the reason names this lane rather than agents in general", context do
    {copy, _agent} = requested_pi_lane(context, "/tmp/unconfirmed-lane-reason")

    html =
      context
      |> show(copy)
      |> element("[data-test='no-agent-chat']")
      |> render()

    assert html =~ "has not confirmed",
           "a person looking at a Pi lane that has not come up was told about hooks " <>
             "and Claude Code, and would go and check the wrong thing. Got: #{html}"
  end
end
