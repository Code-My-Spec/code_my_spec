defmodule CodeMySpecSpex.Story1014.Criterion2379Spex do
  @moduledoc """
  Story 1014 — An agent that has gone quiet stops holding state for everyone else.
  Criterion 2379 — An orphan component stops blocking a gate no edit could clear.

  Rule: A component is reclaimed only when it has no files and no story
  references it.

  The incident this story exists for, filed as 3c6b6b63 during QA of story 727.
  Components are keyed only by project while files are keyed by agent, so four
  components projected from specs no live checkout still had were held alive by
  two harnesses last seen four days earlier. That produced an orphan context which
  `architecture_designed` demanded be resolved and which **no edit in any working
  copy could clear** — the gate stayed unpassable until someone retired the last
  stale harness by hand.

  That asymmetry is the whole bug: a per-agent projection holding a per-project
  one alive.

  ## The arrangement is the ordinary path, then time

  One agent does the normal thing — writes a spec, syncs, gets a component — and
  *then* goes quiet. Constructing that end state directly does not work and would
  not be honest anyway: a channel observation carries no file content, and
  component extraction reads the spec to find its module name.

  ## Read through the components view

  What an engineer sees is the claim. A query would pass against a reclaim that
  emptied a table the view does not read. The list is where the orphan was visible
  and where its absence has to be.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An orphan held alive by a quiet agent is reclaimed" do
    scenario "An orphan component stops blocking a gate no edit could clear" do
      given_ :synced_context_component

      given_ "the checkout that synced it has been quiet for days", context do
        Fixtures.all_agents_go_quiet(context.scope, 96)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "the premise failed: the component is not listed, so there is no " <>
                 "orphan for the reclaim to remove"

        {:ok, context}
      end

      given_ "another agent is still working on the project", context do
        {:ok, Map.put(context, :live, Fixtures.live_agent_scope(context.scope))}
      end

      when_ "the live agent stops, which syncs components", context do
        post_hook(context.live, "/api/hooks/stop", %{
          "session_id" => "spex-live-#{System.unique_integer([:positive])}"
        })

        {:ok, context}
      end

      then_ "the project no longer lists it", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        refute render(view) =~ "ExampleContext",
               "a component whose only files belong to a checkout nobody is running " <>
                 "is still listed. It has no files any live agent can edit and no " <>
                 "story pointing at it, so nothing anyone does in any working copy " <>
                 "can resolve what the graph demands of it. That is 3c6b6b63: a gate " <>
                 "held shut by the projection of an agent that left."

        {:ok, context}
      end
    end
  end
end
