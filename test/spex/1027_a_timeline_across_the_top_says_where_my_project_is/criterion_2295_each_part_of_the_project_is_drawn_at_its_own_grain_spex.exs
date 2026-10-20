defmodule CodeMySpecSpex.Story1027.Criterion2295Spex do
  @moduledoc """
  Story 1027 — A timeline across the top says where my project is.
  Criterion 2295 — Each part of the project is drawn at its own grain: the
  gates either side as marks, the stories in progress as a column each, and
  stories, implementation, architecture and issues as counts.

  Replaces criterion 1026's phases. The project's own gates are serial, so each
  is a mark; the stories are parallel, so they are a chart of columns; the rest
  is a number somebody reads, not a shape.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "The strip draws gates as marks, stories as columns, and the rest as counts",
    criterion: 2295 do
    scenario "Each part of the project is drawn at its own grain" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_grain")}
      end

      when_ "I look at where the project stands", context do
        {:ok, view, _html} = live(context.conn, main_conversation_path(context))
        {:ok, Map.put(context, :view, view)}
      end

      then_ "its gates either side of the stories are marks", context do
        assert has_element?(context.view, "[data-band='early'] [data-test='timeline-step']"),
               "the project's opening gates are not drawn as marks"

        assert has_element?(context.view, "[data-band='late'] [data-test='timeline-step']"),
               "the project's closing gates are not drawn as marks"

        {:ok, context}
      end

      then_ "the stories in progress are a column each", context do
        html = context.view |> element("[data-test='story-chart']") |> render()
        [count] = Regex.run(~r/data-stories="(\d+)"/, html, capture: :all_but_first)
        columns = Regex.scan(~r/data-test="story-column"/, html) |> length()

        assert columns == String.to_integer(count),
               "the chart draws #{columns} columns for #{count} stories in progress"

        {:ok, context}
      end

      then_ "and stories, implementation, architecture and issues are counts", context do
        for {selector, what} <- [
              {"[data-test='story-counts'][data-done][data-backlog][data-retired]", "stories"},
              {"[data-test='component-bar'][data-done][data-not-done][data-unspecified]",
               "implementation"},
              {"[data-test='architecture-mark'][data-cycles][data-depth]", "architecture"},
              {"[data-test='issue-bar'][data-resolved][data-dismissed][data-open]", "issues"}
            ] do
          assert has_element?(context.view, selector), "#{what} is not shown as counts"
        end

        {:ok, context}
      end
    end
  end
end
