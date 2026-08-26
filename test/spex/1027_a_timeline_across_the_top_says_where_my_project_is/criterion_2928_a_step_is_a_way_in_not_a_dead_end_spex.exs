defmodule CodeMySpecSpex.Story965.Criterion2928Spex do
  @moduledoc """
  Story 965 — A timeline across the top says where my project is.
  Criterion 2928 — A step is a way in, not a dead end.

  Rule: Clicking a step opens the page that already answers for it.

  The half that stops this being decoration. A timeline that only reports leaves
  somebody who wants to know more with a screen full of project pages and no
  idea which one answers for the step they were looking at — which is the
  navigation problem the timeline was supposed to remove, moved one click later.

  "The page that already answers for it" is deliberate: no new health pages are
  built here. The requirements view, the stories view and the issues view exist,
  and each step points at whichever of them is about it.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The timeline rides the main agent's conversation, and there is no main agent
  # without somewhere to run it — `ensure_main_agent/1` refuses with
  # `:not_connected`. Same reason story 963's criteria connect one.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "Clicking a step opens the page that already answers for it" do
    scenario "A step is a way in, not a dead end" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_2928")}
      end

      given_ "a timeline with a step for the project's stories", context do
        {:ok, live, html} = live(context.conn, main_conversation_path(context))

        assert html =~ "data-step=\"story_work\"",
               "the timeline has no story-work step, so there is nothing to click"

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      when_ "I click that step", context do
        context.live
        |> element("[data-test=timeline-step][data-step=story_work] a")
        |> render_click()

        {:ok, context}
      end

      then_ "I land on the page that answers for it", context do
        assert_redirect(context.live)

        {:ok, context}
      end

      then_ "and every step offers the same way in", context do
        steps = Regex.scan(~r/data-test="timeline-step"/, context.html) |> length()

        linked =
          Regex.scan(~r/data-test="timeline-step"[^>]*>\s*<a /, context.html) |> length()

        assert linked == steps,
               "#{steps - linked} of #{steps} steps are not clickable. A step that reports " <>
                 "and cannot be opened leaves somebody wanting more with the navigation " <>
                 "problem the timeline was supposed to remove, one click later."

        {:ok, context}
      end
    end
  end
end
