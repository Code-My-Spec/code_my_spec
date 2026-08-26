defmodule CodeMySpecSpex.Story965.Criterion2940Spex do
  @moduledoc """
  Story 965 — A timeline across the top says where my project is.
  Criterion 2940 — The phase I am in is readable and the rest is context.

  Rule: The phase the project is in is shown in detail; the phases either side
  are collapsed.

  How thirteen requirements fit across the top without becoming the build log
  this story exists to replace. John: *"we could absolutely group and focus — so
  we could have shaping and then zoom in while it's in that phase, so you could
  show the previous and following phases zoomed out and the current one zoomed
  in."*

  Nothing is hidden and nothing is dropped: the whole graph is on the line, and
  only one part of it is legible at a time. That is the difference between this
  and cutting the list down to five — a cut list cannot answer a question about
  a step it left out.
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

  spex "The phase the project is in is shown in detail; the phases either side are collapsed" do
    scenario "The phase I am in is readable and the rest is context" do
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

      then_ "exactly one phase is expanded", context do
        expanded =
          Regex.scan(~r/data-test="timeline-phase"[^>]*data-expanded="true"/, context.html)

        assert length(expanded) == 1,
               "#{length(expanded)} phases are expanded. Two is the build log again and " <>
                 "none is a line of unlabelled marks."

        {:ok, context}
      end

      then_ "and the phases either side of it are collapsed", context do
        phases = Regex.scan(~r/data-test="timeline-phase"/, context.html) |> length()

        collapsed =
          Regex.scan(~r/data-test="timeline-phase"[^>]*data-expanded="false"/, context.html)
          |> length()

        assert phases > 1,
               "the timeline has #{phases} phase(s), so there is nothing either side to " <>
                 "collapse and zoom is not being exercised"

        assert collapsed == phases - 1,
               "#{phases - 1 - collapsed} phase(s) are neither expanded nor collapsed"

        {:ok, context}
      end

      then_ "and a collapsed phase still draws a mark for every step it has", context do
        # The claim this block exists for is visual, and the counting blocks
        # above pass either way — which is how a collapsed phase came to render
        # its name and nothing else. A step used to draw only a tick, and only
        # when it was done, so three of five phases were bare words and the one
        # with a single done step read as "one thing here" rather than "one of
        # five done".
        #
        # Bounded to the timeline's own list: the conversation below it is not
        # part of this claim and must not be counted.
        timeline = context.html |> String.split("</ol>") |> hd()

        collapsed =
          timeline
          |> String.split(~s(data-test="timeline-phase"))
          |> tl()
          |> Enum.filter(&String.contains?(&1, ~s(data-expanded="false")))

        assert collapsed != [], "no collapsed phase to check"

        for phase <- collapsed do
          steps = Regex.scan(~r/data-test="timeline-step"/, phase) |> length()
          marks = Regex.scan(~r/size-2 rounded-full/, phase) |> length()

          assert marks == steps,
                 "a collapsed phase has #{steps} step(s) and draws #{marks} mark(s). " <>
                   "Zoomed out is not absent — a phase you cannot count the steps of " <>
                   "answers none of the questions the neighbouring phases are there for."
        end

        {:ok, context}
      end

      then_ "and the whole graph is still on the line", context do
        steps = Regex.scan(~r/data-test="timeline-step"/, context.html) |> length()

        assert steps >= 13,
               "only #{steps} steps are on the timeline. The project has thirteen " <>
                 "requirements of its own and the point of zoom rather than a cut list is " <>
                 "that none of them is dropped — a cut list cannot answer about a step it " <>
                 "left out."

        {:ok, context}
      end
    end
  end
end
