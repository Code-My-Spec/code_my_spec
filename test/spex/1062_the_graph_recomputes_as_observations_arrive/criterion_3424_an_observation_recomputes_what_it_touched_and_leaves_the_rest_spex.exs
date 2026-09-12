defmodule CodeMySpecSpex.Story1062.Criterion3424Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3424 — An observation recomputes what it touched and leaves the rest.

  Rule: a recompute fires only when an observation has moved something the
  graph depends on.

  ## What this is for

  Every other criterion on this story asserts the graph moves when an
  observation arrives. None of them bounds the cost, so recomputing the whole
  project on every observation satisfies the story as written — which is what
  it does.

  Measured on this project with a handful of agents, 2026-09-12: 348 full
  computes in one log, median 2.6s, p90 5.9s, max 14.8s, 116 of them triggered
  by stop hooks, which is why agents' turns were ending in timeouts that named
  the network. Edges are the expensive half — 6489ms of a 10203ms compute,
  23918 edges — and edges only change when components or stories do, never when
  an observation lands on one story.

  ## What it observes

  `checked_at` per requirement. One `computed_at` for the whole graph cannot
  answer this: every node moves together whether or not the work was
  necessary, so the reading that separates "recomputed what it touched" from
  "recomputed everything" does not exist at graph grain. Exposing it per node
  was the testability change this criterion needed; the rows have carried it
  all along and nothing read it.

  ## Why it is red, and what would make it green

  An observation busts a single fingerprint computed over every input, so the
  next read rebuilds all of it and every node's `checked_at` moves — including
  the requirements of a story the observation has nothing to do with.

  Green needs requirements to carry their own freshness, traceable to the
  sources they were computed from, so an observation costs work in proportion
  to what it changed. `Projection.for_file/2` already maps a changed file to
  the requirements it bears on, and its own docstring says that is why the
  graph became rows: the old payload "has no way to say which of its 5,000
  nodes a changed file touches, so any change meant discarding the whole
  payload". The rows solved it; the fingerprint reintroduced it.

  ## Two earlier drafts, both removed

  Worth recording, because both failed the way criterion 3358 documents about
  itself — red for a reason other than the one named:

  - a file appearing under a component: `scan_working_copy/1` syncs files but
    derives no components, so the graph had no component nodes to compare and
    the assertion failed on an empty list;
  - `add_scenario` without a rule, and `add_rule` with an integer `story_id`:
    both refused, so the observation never landed and the failure was in the
    `given_`.

  The setup below is 1063/criterion_3341's, which performs this observation for
  real: persona linked first, then the rule, then the scenario, with `story_id`
  as a string throughout.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.{AddRule, AddScenario}
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.{Fixtures, ProjectStateFixtures}

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An observation recomputes what it touched and leaves the rest" do
    scenario "an observation bears on one story only" do
      given_ "two stories in the graph, one of them ready for an observation", context do
        touched = create_story(context.scope, title: "The story it is about", description: "one")
        other = create_story(context.scope, title: "A story it is not about", description: "two")

        frame = %Frame{assigns: %{current_scope: context.scope}}

        # A rule cannot be added to a story with no persona linked — the tool
        # refuses it. Persona first, then rules, then scenarios.
        context = ProjectStateFixtures.apply_persona(context)

        {:reply, link, _frame} =
          LinkPersonaToStory.execute(
            %{persona_id: context.persona_id, story_id: touched.id},
            frame
          )

        refute link.isError, inspect(link)

        {:reply, rule, _frame} =
          AddRule.execute(
            %{story_id: to_string(touched.id), statement: "The thing holds."},
            frame
          )

        refute rule.isError, inspect(rule)

        before = read_settled_graph(context)

        # Stamp rather than sleep. `checked_at` is second-resolution, so
        # without this the reading before the observation and the reading
        # after it land in the same second and a recompute is invisible.
        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        {:ok,
         context
         |> Map.put(:touched_id, touched.id)
         |> Map.put(:other_id, other.id)
         |> Map.put(:before, before)}
      end

      when_ "a scenario is added to the first story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, added, _frame} =
          AddScenario.execute(
            %{
              story_id: to_string(context.touched_id),
              rule_statement: "The thing holds.",
              title: "The thing holds in the ordinary case",
              kind: "happy_path",
              body: "Given a thing\nWhen it is used\nThen it holds"
            },
            frame
          )

        refute added.isError, inspect(added)

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "the requirements it bears on are reconsidered", context do
        # Compared against the backdated stamp rather than the first reading:
        # anything the observation recomputed carries a time from after it.
        refute freshness(context.after, context.touched_id) ==
                 freshness(context.before, context.touched_id),
               """
               The observation did not reach the requirements it bears on.

               A scenario was added to this story. If its requirements do not
               move, an agent is handed back work the observation has already
               changed — which is what the rest of this story is about.

               before: #{inspect(freshness(context.before, context.touched_id))}
               after:  #{inspect(freshness(context.after, context.touched_id))}
               """

        {:ok, context}
      end

      then_ "and the ones it has nothing to do with are left as they were", context do
        before_other = freshness(context.before, context.other_id)
        after_other = freshness(context.after, context.other_id)

        assert after_other == before_other,
               """
               An observation about one story recomputed another story's
               requirements too.

               Nothing about that story moved. Its requirements were recomputed
               because the graph is recomputed whole: one fingerprint over every
               input, so any observation busts all of it and the next read
               rebuilds every node and edge in the project to answer a question
               about one story.

               That is the cost this criterion bounds. Measured here: 348
               computes in one log, median 2.6s, max 14.8s, 116 of them from
               stop hooks. At a hundred connected people it is the difference
               between working and queueing.

               before: #{inspect(before_other)}
               after:  #{inspect(after_other)}
               """

        {:ok, context}
      end
    end
  end

  # One story's requirements and when each was last worked out, as the endpoint
  # reports it. Sorted so two readings compare as sets rather than by whatever
  # order the graph returned them in.
  defp freshness(graph, story_id) do
    graph["nodes"]
    |> Enum.filter(&(&1["entity_type"] == "story" and &1["entity_id"] == story_id))
    |> Enum.map(&{&1["name"], &1["checked_at"]})
    |> Enum.sort()
  end
end
