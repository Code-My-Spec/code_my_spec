defmodule CodeMySpecSpex.Story1062.Criterion3619Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3619 — A component's siblings are not rewritten because it changed.

  Rule: an observation costs work in proportion to what it changed, not to the
  size of the project.

  ## Measured on dev, and the arithmetic is exact

      01:19:08  [Files.ComponentSync] 1 components synced in 21ms (0 changed)
      01:19:10  recomputed 108 of 1547 — 105 entity(ies) stale
                                          (0/58 stories, 105/1145 components)

  **Zero changed**, by the sync's own count, and a hundred and five components
  went stale. Two files had moved, on one checkout, belonging to
  `CodeMySpec.Billing` and `CodeMySpecWeb.IntakeLive.Procedural`. Those two have
  101 and 3 siblings. 101 + 3 + their parents is the 105.

  `expand_component_families/2` is the multiplier. One test file changing under
  one child marks every child of that context stale.

  ## Why the family is expanded, and why that is not this

  It is not an accident, and the reason is real. `component_families/1` decides
  top-level from nested by asking whether each component's parent is *in the set
  it was given*, so a child narrowed to itself is classified top-level, runs its
  own template, and invents an `implementation_file` node the whole-project pass
  never produces. 549 of this project's components are nested; every one of them
  computed alone would do it.

  So the family has to be **in the context**. That is a different claim from
  every member's answer having moved, and the two were the same set. A sibling's
  file did not change, so its verdict cannot have — and rewriting its row stamps
  `checked_at` on a requirement nothing touched.

  The event path already draws this distinction: `recompute_entity/3` returns
  `{covered, nodes}` precisely because for a component the two differ. The
  batched pass collapsed them.

  ## What it observes

  `checked_at`, backdated first. The stamp is `truncate(:second)` into a
  precision-0 column, so a pass inside one second is indistinguishable from one
  that did nothing, and this scenario reads "nothing moved" as its own setup
  having failed.

  `checked_at` is the right instrument here and the wrong one in
  [[criterion 3618]] — there it moves whether or not the work was necessary,
  because `upsert_all/3` stamps every row it is handed. That is exactly the
  property under test here: the sibling must not be handed to it at all.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  spex "One child changing is one child's worth of work" do
    scenario "a context with three children, one of which is edited" do
      given_ :context_with_three_children

      given_ "a settled graph, old enough to see a rewrite", context do
        :ok = Fixtures.settle_graph(context.scope)
        _warm = read_settled_graph(context)
        :ok = Fixtures.settle_graph(context.scope)
        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        before = stamps(read_graph(context))

        assert before != %{}, "nothing is stored, so no pass can leave anything alone"

        {:ok, Map.put(context, :before, before)}
      end

      when_ "one child's spec file is edited", context do
        # Still valid, and still a schema with no dependencies, so the shape does
        # not move — only this one component's files. An edit into invalidity
        # would move `spec_valid`'s verdict too, and then "the sibling was left
        # alone" could be read off a verdict rather than off the work.
        :ok =
          Fixtures.write_env_file(
            context.environment,
            Content.spec_path(context.child_schema.module_name),
            Content.child_spec(context.child_schema.module_name,
              type: "schema",
              dependencies: [],
              description: "Edited after the graph had been computed."
            )
          )

        :ok = Fixtures.scan_working_copy(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :after, stamps(read_graph(context)))}
      end

      then_ "the child whose file it is gets recomputed", context do
        assert moved?(context, context.child_schema.id),
               """
               A component's spec file changed and its requirements were not
               recomputed.

               Everything below is about what that pass should *not* also have
               done. If it did nothing, the sibling being untouched is an
               absence rather than a saving.
               """

        {:ok, context}
      end

      then_ "and its siblings are not", context do
        siblings =
          [context.child_repository, context.child_service]
          |> Enum.filter(&moved?(context, &1.id))
          |> Enum.map(& &1.module_name)

        assert siblings == [],
               """
               One child's file changed and #{length(siblings)} sibling(s) were
               rewritten with it: #{Enum.join(siblings, ", ")}.

               `expand_component_families/2` puts the whole family in the stale
               set, and the stale set is both "what to put in the context" and
               "whose rows to write". The first is owed — `component_families/1`
               misclassifies a child narrowed to itself and invents nodes. The
               second is not: these siblings' files did not move, so their
               answers did not.

               Measured on dev at the size that matters: one child edited under
               `CodeMySpec`, which has 101 children, and 105 components were
               recomputed for it.
               """

        {:ok, context}
      end

      then_ "and neither is the parent context", context do
        refute moved?(context, context.parent_context.id),
               """
               A child's file changed and the parent context was rewritten.

               The parent's own requirements read the parent's own files and the
               *ids* of its children — `Freshness.component/2` hashes
               `{:children, ids(...)}`, not the children's contents. A child's
               spec being edited changes neither, so the parent is in the family
               for instantiation and not for recomputation.
               """

        {:ok, context}
      end
    end
  end

  defp stamps(graph) do
    (graph["nodes"] || [])
    |> Map.new(&{{&1["entity_type"], to_string(&1["entity_id"]), &1["name"]}, &1["checked_at"]})
  end

  # Whether any requirement belonging to this component was restamped.
  defp moved?(context, component_id) do
    Enum.any?(context.before, fn {{type, id, _name} = key, was} ->
      type == "component" and id == to_string(component_id) and
        Map.get(context.after, key) != was
    end)
  end
end
