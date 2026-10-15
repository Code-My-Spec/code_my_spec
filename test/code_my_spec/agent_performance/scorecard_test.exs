defmodule CodeMySpec.AgentPerformance.ScorecardTest do
  @moduledoc """
  The headline rates the performance page leads with -- the one-off
  scorecard's findings (2026-10-04), computed this week against last.
  """
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.AgentPerformance.Scorecard
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    coder = Fixtures.running_agent(context.scope, role: "coding")
    %{coder: coder}
  end

  test "an expired tap-out is a lost decision, and past a quarter of them is bad", context do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    tap_out(context, "expired", now)
    tap_out(context, "approved", now)
    tap_out(context, "pending", now)

    kpi = kpi(context, :tap_out_expiry)
    assert kpi.value == 0.5, "pending tap-outs are undecided, so only the two decided count"
    assert kpi.severity == :bad

    assert %{coding: %{"expired" => 1, "approved" => 1, "pending" => 1}} =
             Scorecard.load(context.scope).tap_outs
  end

  test "an answered question's wait runs from asking to answering", context do
    asked = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    question(context, "answered", asked, DateTime.add(asked, 30 * 60, :second))

    kpi = kpi(context, :question_wait)
    assert_in_delta kpi.value, 30.0, 0.1
    assert kpi.severity == :good

    assert %{coding: %{median_minutes: wait}} = Scorecard.load(context.scope).questions
    assert_in_delta wait, 30.0, 0.1
  end

  test "failed turns count the harness's failure notices, and tool failures make a rate by role",
       context do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        context.scope.active_account_id,
        context.scope.active_project_id,
        context.coder.id
      )

    Repo.insert!(%Message{
      conversation_id: conversation.id,
      role: :operator,
      sender_id: "operator",
      content: [%{"type" => "text", "text" => "Your last turn failed: provider error"}]
    })

    for failed? <- [true, false, false, false] do
      Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: :tool,
        tool_call_id: "call-#{System.unique_integer([:positive])}",
        tool_failed: failed?
      })
    end

    assert kpi(context, :failed_turns).value == 1
    assert kpi(context, :tool_failure_rate).value == 0.25

    assert [%{role: :coding, calls: 4, failed: 1, failed_turns: 1}] =
             Scorecard.load(context.scope).roles
  end

  test "a rate with no data this week says so rather than reading as zero", context do
    kpi = kpi(context, :qa_first_pass)
    assert kpi.value == nil
    assert kpi.severity == :none
    assert length(kpi.days) == 7
  end

  defp kpi(context, key),
    do: context.scope |> Scorecard.load() |> Map.fetch!(:kpis) |> Enum.find(&(&1.key == key))

  defp tap_out(context, status, at) do
    Repo.insert!(%PermissionRequest{
      user_id: context.user.id,
      agent_id: context.coder.id,
      tool_name: "tap_out",
      tool_input: %{"reason" => "blocked"},
      status: status,
      inserted_at: at,
      updated_at: at
    })
  end

  defp question(context, status, asked, answered) do
    Repo.insert!(%QuestionRequest{
      user_id: context.user.id,
      agent_id: context.coder.id,
      title: "Which way?",
      status: status,
      questions: [%{"question" => "Which way?"}],
      inserted_at: asked,
      updated_at: answered
    })
  end
end
