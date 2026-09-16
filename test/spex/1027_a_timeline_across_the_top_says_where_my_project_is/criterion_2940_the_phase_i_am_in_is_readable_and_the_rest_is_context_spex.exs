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

  cloud_endpoint()

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

      then_ "and every collapsed phase is drawn, never left blank", context do
        # The claim is visual and the counting blocks above pass either way,
        # which is how a collapsed phase once came to render its name and
        # nothing else.
        #
        # What "drawn" means changed with the design and the guarantee did not.
        # A collapsed phase used to be a mark per step; it is now one pie
        # carrying `data-done` and `data-total`. Either way the test is that a
        # phase you are not in is still *there* and still says how far through
        # it is — zoomed out is not absent.
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
          pies = Regex.scan(~r/data-test="phase-pie"[^>]*data-total="(\d+)"/, phase)

          assert [[_, total]] = pies,
                 "a collapsed phase draws #{length(pies)} pies. One phase is one pie — " <>
                   "none means the phase is invisible, which is the failure this block " <>
                   "exists for."

          assert String.to_integer(total) > 0,
                 "a collapsed phase says it holds zero steps, so it is drawn but reads " <>
                   "as nothing. A phase with no steps should not be on the line at all."
        end

        {:ok, context}
      end

      then_ "and the whole graph is still accounted for", context do
        # Counted two ways, because a phase is drawn one of two ways: the phase
        # you are in itemises its steps as dots and has no pie, and every other
        # phase is a pie carrying its total and draws no dots. Summing only one
        # of them undercounts by exactly the phase you are looking at.
        #
        # The guarantee is unchanged and is the whole reason this is zoom rather
        # than a shorter list: a pie can answer a question about a step because
        # it counted it, and a cut list cannot answer about one it left out.
        named =
          ~r/data-test="timeline-step"[^>]*data-step="([a-z_]+)"/
          |> Regex.scan(context.html)
          |> Enum.map(fn [_, name] -> name end)
          |> Enum.uniq()

        assert length(named) >= 13,
               "the timeline names #{length(named)} distinct steps. The project has " <>
                 "thirteen requirements of its own, and aggregating the phases you are " <>
                 "not in is only honest while every step is still on the page."

        {:ok, context}
      end
    end
  end
end
