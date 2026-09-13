defmodule CodeMySpecSpex.Story990.Criterion3401Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3401 — Choosing local never asks for payment.

  Rule: nothing is provisioned on our infrastructure for a visitor who chose
  to run their own copy, so there is nothing there for payment to gate.

  The half of the payment-gate rule that should already hold: `local` never
  reaches `Workspaces.boot/1` at all (`IntakeLive.Workspace.mount_workspace/3`
  branches to `assign_local/1` instead), so this criterion is the check that
  the payment gate story 3400 adds never leaks onto a path that was never
  going to touch the shared host.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A visitor running their own copy is never asked to pay" do
    scenario "Choosing local never asks for payment" do
      given_ "a visitor who has signed up and reaches the local-or-cloud choice", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "they choose local", context do
        to = confirm_plan(context.view, %{location: "local"})

        assert to == "/build/workspace",
               "expected a signed-in visitor choosing local to be sent to their workspace, " <>
                 "got #{inspect(to)}"

        {:ok, live, html} = live(context.conn, to)

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "they move straight into the agent-guided install walkthrough", context do
        assert has_element?(context.live, "[data-test='local-instructions']"),
               "expected the local install walkthrough to be shown immediately, got: " <>
                 "#{context.html}"

        {:ok, context}
      end

      then_ "they are never asked to pay to continue", context do
        refute context.html =~ ~r/\bpay\b|payment|card details/i,
               "a visitor who chose to run their own copy was asked to pay, got: " <>
                 "#{context.html}"

        {:ok, context}
      end
    end
  end
end
