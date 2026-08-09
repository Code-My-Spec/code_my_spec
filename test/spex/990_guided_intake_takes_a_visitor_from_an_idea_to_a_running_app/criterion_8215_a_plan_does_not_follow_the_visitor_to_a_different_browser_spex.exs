defmodule CodeMySpecSpex.Story990.Criterion8215Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8215 — A plan does not follow the visitor to a different browser.

  Rule: an abandoned plan is still there when the visitor comes back.

  The failure side of the same rule, and it is a designed outcome rather than
  a fault. The plan is keyed to an anonymous cookie, so another browser is
  another visitor as far as we can tell — there is no email to look them up
  by, which is the point. What matters is that they get a fresh start rather
  than an error about something they have no way to fix.

  Surface: the `/build` LiveView, mounted on a second, unrelated connection.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "A plan belongs to the browser that made it" do
    scenario "A plan does not follow the visitor to a different browser" do
      given_ "a visitor who reached a plan and left without signing up", context do
        conn = get(build_conn(), "/build")
        {:ok, view, _html} = live(conn)

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        view
        |> answer_shaping_questions()

        {:ok, context}
      end

      when_ "they return from a different browser", context do
        {:ok, _view, html} = live(build_conn(), "/build")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "they are offered a fresh start", context do
        assert context.html =~ "What do you want to build?",
               "expected a fresh start on an unrelated browser, got: #{context.html}"

        refute context.html =~ "salon owners",
               "expected the other browser's plan to stay where it was"

        {:ok, context}
      end

      then_ "nothing implies their earlier plan was lost through a fault", context do
        for alarm <- [~r/error/i, ~r/expired/i, ~r/not found/i, ~r/sorry/i] do
          refute context.html =~ alarm,
                 "expected no failure language on a fresh start, found #{inspect(alarm)}"
        end

        {:ok, context}
      end
    end
  end
end
