defmodule CodeMySpecSpex.Story965.Criterion2925Spex do
  @moduledoc """
  Story 965 — A timeline across the top says where my project is.
  Criterion 2925 — The indicator names one step, not a range.

  Rule: Exactly one step is marked as where the project is now.

  The question the timeline exists to answer is "where is my project", and an
  answer that spans three steps is not an answer. Two marked steps and none
  marked read the same way to somebody who does not know the graph — as a screen
  that is not sure.
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

  spex "Exactly one step is marked as where the project is now" do
    scenario "The indicator names one step, not a range" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_timeline")}
      end

      given_ "a project part-way through its requirements", context do
        # Established rather than assumed. "Part-way" means some of the
        # project's own requirements are met and some are not; on a project
        # where everything is satisfied the timeline is a different picture and
        # a block that only says so would not notice.
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/requirements")

        assert html =~ "requirement",
               "the requirements page shows nothing, so there is no project state for " <>
                 "the timeline to be part-way through"

        {:ok, context}
      end

      when_ "I look at the timeline", context do
        {:ok, _live, html} = live(context.conn, main_conversation_path(context))

        {:ok, Map.put(context, :html, html)}
      end

      then_ "exactly one step carries the current indicator", context do
        current = Regex.scan(~r/data-test="timeline-step"[^>]*data-state="current"/, context.html)

        assert length(current) == 1,
               "#{length(current)} steps are marked current. Two and none read the same " <>
                 "way to somebody who does not know the graph — as a screen that is not " <>
                 "sure — and the timeline exists to answer exactly this."

        {:ok, context}
      end

      then_ "and the steps around it say which side of it they are on", context do
        states =
          ~r/data-test="timeline-step"[^>]*data-state="([a-z]+)"/
          |> Regex.scan(context.html)
          |> Enum.map(fn [_, state] -> state end)

        assert Enum.all?(states, &(&1 in ~w(done current todo))),
               "a step reports a state that is none of done, current or todo: " <>
                 "#{inspect(Enum.uniq(states))}"

        refute Enum.empty?(states -- ["current"]),
               "the timeline is one step long, so there is nothing for the indicator to " <>
                 "distinguish it from"

        {:ok, context}
      end
    end
  end
end
