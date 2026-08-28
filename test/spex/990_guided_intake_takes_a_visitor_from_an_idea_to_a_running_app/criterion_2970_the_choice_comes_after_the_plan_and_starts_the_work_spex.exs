defmodule CodeMySpecSpex.Story990.Criterion2970Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 2970 — The choice comes after the plan and starts the work.

  Rule: The visitor chooses where their working copy runs once, after seeing the
  plan and before anything is provisioned.

  Two claims, and the second is the one with teeth.

  **After the plan**, because the question is technical and the visitor has not
  been shown anything yet when intake begins. Asking "local or cloud" before
  they have seen what they are getting asks someone to decide about
  infrastructure for a thing that does not exist.

  **Before anything is provisioned**, because a development instance is a real
  container on a real box. Starting one for every visitor who describes an idea
  spends that on everybody who wanders off, and most of them do — the whole
  reason the interview runs during the boot is that this funnel leaks.

  So the refutation matters more than the assertion here: nothing may exist
  until they say where they want it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)

    :ok
  end

  spex "Where it runs is the visitor's choice, and it is what starts the work" do
    scenario "The choice comes after the plan and starts the work" do
      given_ "a visitor looking at the plan for what they described", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      then_ "nothing has been provisioned for them yet", context do
        refute render(context.view) =~ "Setting up",
               "something was already being provisioned before the visitor said " <>
                 "where they wanted it. A development instance is a real container " <>
                 "on a real box, and this funnel leaks by design — starting one for " <>
                 "everybody who describes an idea spends it on everybody who leaves."

        {:ok, context}
      end

      # On the confirmation card rather than a step of its own. The criterion is
      # about *when* the choice happens and that nothing is provisioned before
      # it — not about it having its own page, which would put a second gate in
      # a flow whose whole complaint was having too many.
      when_ "they say where they want it to run", context do
        context.view
        |> form("form[phx-submit=confirm_names]", %{
          plan: %{
            account_name: "Acme",
            project_name: "Salon Book",
            needs_sign_in: "true",
            separate_copies: "true",
            location: "cloud"
          }
        })
        |> render_submit()

        {:ok, context}
      end

      then_ "their working copy starts being provisioned there", context do
        {:ok, _view, html} = live(context.conn, "/build/workspace")

        assert html =~ ~r/getting ready|running|building|question 1 of/i,
               "saying where it should run started nothing, so the visitor is left " <>
                 "on a plan with no way forward. Got: #{html}"

        {:ok, context}
      end
    end
  end
end
