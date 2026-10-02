defmodule CodeMySpecSpex.Story70.Criterion5871Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5871 — Orphan context appears post-execution and
  architecture_designed becomes the next gate.

  Rule: `architecture_designed` is unsatisfied whenever the project DB
  contains an orphan **context** — a context-shaped component
  (`context`, `coordination_context`, `live_context`) not linked to a
  story, with no transitively story-linked descendant, not transitively
  depended on by a story-linked context, and not classified as
  infrastructure. Loose modules / liveviews / schemas / etc. are owned
  by their parent context and are not flagged on their own.

  This spec composes `:fully_satisfied_project` — every project gate
  green, including a `proposal.md` already on disk — and adds a new
  orphan context via the file sync surface (spec declares
  `## Type\\ncontext`, no story link, no covering dependency, not in
  infrastructure_paths). The architecture_designed node in the rendered
  graph must NOT be the satisfied color: the harness should route the
  agent back to architecture until the orphan is resolved.

  Surface: `/projects/:name/sync` LiveView (to land the orphan) and
  `/projects/:name/requirements/graph` (to read the graph state).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers, only: [design!: 4, implementation!: 2, sync!: 1]

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  @satisfied "#ff3838"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Orphan in DB unsatisfies architecture_designed regardless of proposal.md",
    criterion: 34 do
    scenario "Orphan appears post-execution and architecture_designed becomes the next gate" do
      given_ :fully_satisfied_project

      and_ "an orphan context is designed, with its code",
           context do
        # Orphan must be context-shaped — `ArchitectureChecker.orphans/1`
        # only flags contexts (the architectural unit), not loose
        # modules/liveviews/etc.
        design!(context, "MyOrphanContext", [],
          description: "An orphan context with no story link and no dependency edge."
        )

        implementation!(context, "MyOrphanContext")
        sync!(context)

        {:ok, context}
      end

      when_ "the engineer renders the requirements graph", context do
        {:ok, _live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "architecture_designed is not rendered as satisfied", context do
        arch_node =
          GraphAssertions.find_node(
            context.graph,
            "project",
            context.project.id,
            "architecture_designed"
          )

        assert arch_node,
               "expected architecture_designed node to exist in the project graph"

        refute arch_node["attributes"]["color"] == @satisfied,
               "expected architecture_designed to be unsatisfied while an orphan is present in the project DB, got color: #{arch_node["attributes"]["color"]}"

        {:ok, context}
      end
    end
  end
end
