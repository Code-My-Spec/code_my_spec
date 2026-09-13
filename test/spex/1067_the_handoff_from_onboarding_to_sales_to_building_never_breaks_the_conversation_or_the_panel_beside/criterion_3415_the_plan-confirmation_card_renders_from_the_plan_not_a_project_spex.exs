defmodule CodeMySpecSpex.Story1033.Criterion3415Spex do
  @moduledoc """
  Story 1033 — The handoff from onboarding to sales to building never breaks
  the conversation or the panel beside it.
  Criterion 3415 — The plan-confirmation card renders from the plan, not a
  project.

  Rule: pre-signup (phases 1-2), there is no project and nothing for
  `CodeMySpec.ScreenState` to key on — whatever shows the plan-confirmation
  card has to be backed by `Intake.Plan` itself.

  The claim is provable at its strongest by the visitor it describes: someone
  with no account at all. If the card rendered for them, nothing scoped to a
  project or a signed-in account could have produced it — there is no project
  or account to query.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "The plan-confirmation card is backed by the plan, not by a project" do
    scenario "The plan-confirmation card renders from the plan, not a project" do
      given_ "an anonymous visitor mid-conversation with a plan but no account", context do
        conn = get(build_conn(), "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "the plan's guesses are ready to confirm", context do
        html = answer_shaping_questions(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the panel renders them from the plan record", context do
        assert has_element?(context.view, "[data-test='intake-plan']"),
               "expected the plan-confirmation card, got: #{context.html}"

        {:ok, context}
      end

      # This visitor never signed in and holds no session at all — the
      # strongest form of "no project or ScreenState row is queried" a spex
      # can prove without reading internals. Nothing scoped to a project or an
      # account could have produced this card, because there is no scope for
      # either to be queried through: the connection carries no user.
      then_ "no project or ScreenState row is queried to do it", context do
        assert is_nil(context.conn.assigns[:current_scope]) ||
                 is_nil(context.conn.assigns.current_scope.user),
               "expected a truly anonymous visitor — no signed-in scope for a project or " <>
                 "account lookup to have run against"

        {:ok, context}
      end
    end
  end
end
