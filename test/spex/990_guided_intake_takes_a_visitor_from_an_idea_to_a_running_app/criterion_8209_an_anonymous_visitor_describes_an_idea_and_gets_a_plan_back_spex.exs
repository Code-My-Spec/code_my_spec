defmodule CodeMySpecSpex.Story990.Criterion8209Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8209 — An anonymous visitor describes an idea and gets a plan back.

  Rule: a visitor gets a plan for what they described without signing in.

  The whole bet of guided intake is that the current funnel leaks because
  nothing has happened yet when we ask for an email. So the plan has to be
  reachable with no account, no sign-in and no address — if any of those
  are required to get here, the bet is not being made.

  Surface: the `/build` LiveView, driven anonymously. Nothing in this spex
  logs in, which is the point of it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  @description "a booking tool for hair salons, so owners can see their week"

  spex "A visitor gets a plan for what they described without signing in" do
    scenario "An anonymous visitor describes an idea and gets a plan back" do
      given_ "a visitor who has never signed in", context do
        {:ok, Map.put(context, :conn, build_conn())}
      end

      given_ "they have opened the intake page", context do
        {:ok, view, html} = live(context.conn, "/build")

        assert html =~ "What do you want to build?",
               "expected the intake page to ask what they want to build, got: #{html}"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "they describe what they want to build in their own words", context do
        context.view
        |> form("form[phx-submit=describe]", %{description: @description})
        |> render_submit()

        html =
          context.view
          |> answer_shaping_questions(["yes", "yes", "salon owners"])

        {:ok, Map.put(context, :html, html)}
      end

      then_ "they are shown a plan describing what they are building", context do
        assert context.html =~ "what I think you&#39;re building",
               "expected a plan back, got: #{context.html}"

        assert context.html =~ "salon owners",
               "expected the plan to be about what they described, got: #{context.html}"

        {:ok, context}
      end

      then_ "they were never asked to sign in or provide an email", context do
        refute context.html =~ ~r/password/i,
               "expected no password field before the gate, got: #{context.html}"

        refute context.html =~ ~r/type="email"/,
               "expected no email field before the gate, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
