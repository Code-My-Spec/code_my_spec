defmodule CodeMySpecSpex.Story965.Criterion3032Spex do
  @moduledoc """
  Story 1027 — A timeline across the top says where my project is.
  Criterion 1106 — The step I am on says what is happening, in words I
  already use.

  Rule: the current step carries about two sentences of plain-language
  detail, readable without knowing what a requirement, a spec or a working
  copy is.

  `CodeMySpec.Requirements.PlainLanguage` already holds exactly this text,
  keyed by requirement name, by design -- its own moduledoc: "Two sentences,
  give or take... No module names, file paths, ids or counts of internals."
  But `ProjectTimeline`'s own `step/3` reads only `:title` and `:abbrev` out
  of that map; `:detail` is fetched and dropped, and the render shows
  nothing but the pill's abbreviation plus a tooltip/screen-reader title.
  This spec is written against the criterion, not against that gap: it
  names the anchor the detail text would need (`data-test="current-step-
  detail"`), the same convention every other piece of this component
  already follows (`data-test="current-step"`, `data-test="timeline-step"`).
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphAssertions
  alias Ecto.Adapters.SQL.Sandbox

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

  spex "The step I am on says what is happening, in words I already use",
    criterion: 1106 do
    scenario "The step I am on says what is happening, in about two sentences" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_timeline")}
      end

      given_ "a project part-way through its design phase", context do
        # Established the same way sibling criteria 1012 and 1013 do: a fresh
        # project's own requirements have some satisfied and some not by
        # construction (nothing starts fully satisfied), which is what
        # "part-way through" means here. The check is that the graph draws
        # project gates at all -- that there is a project state for the
        # timeline to be part-way through -- not any one specific phase.
        {:ok, _live, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        gates =
          for %{"attributes" => %{"entity_type" => "project"}} = node <-
                GraphAssertions.extract_graph!(html)["nodes"],
              do: node

        assert gates != [],
               "the graph draws no project gates, so there is no project state for " <>
                 "the timeline to be part-way through"

        {:ok, context}
      end

      when_ "I look at the timeline", context do
        {:ok, _live, html} = live(context.conn, main_conversation_path(context))

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the step it is on says what is happening in about two sentences", context do
        assert context.html =~ "data-test=\"current-step-detail\"",
               "the current step carries no explanatory detail at all -- only its " <>
                 "abbreviation and a tooltip title, which is what this criterion exists " <>
                 "to add"

        [_, detail] =
          Regex.run(~r/data-test="current-step-detail"[^>]*>([^<]+)</, context.html)

        sentence_count =
          detail
          |> String.trim()
          |> String.split(~r/[.!?]+/, trim: true)
          |> length()

        assert sentence_count in 1..3,
               "the current step's detail reads as #{sentence_count} sentence(s), not " <>
                 "\"about two\": #{inspect(detail)}"

        {:ok, Map.put(context, :detail, detail)}
      end

      then_ "I could read them without knowing what a requirement, a spec or a working copy is",
            context do
        lower = String.downcase(context.detail)

        for jargon <- ["requirement", "spec", "working copy", "criterion", "node", "graph"] do
          refute lower =~ jargon,
                 "the current step's own explanation uses \"#{jargon}\", which is exactly " <>
                   "the kind of word a non-technical user reading it would not follow: " <>
                   inspect(context.detail)
        end

        {:ok, context}
      end
    end
  end
end
