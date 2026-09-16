defmodule CodeMySpecSpex.Story1062.Criterion3426Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3426 — A file changing reconsiders the requirements that file
  answers.

  Rule: a recompute fires only when an observation has moved something the
  graph depends on.

  ## The input the graph was built for

  `Projection.for_file/2` exists to map a changed file to the requirements it
  bears on, and its docstring says that is why the graph became rows at all:
  the old payload "has no way to say which of its 5,000 nodes a changed file
  touches, so any change meant discarding the whole payload". Files are the
  highest-frequency observation this system takes — every keystroke an agent
  commits — so if any input has to be narrow, it is this one.

  ## Content, not the row

  `Freshness.component/2` keys files as `{path, fingerprint, valid}`. It has to
  be the content: `Files.upsert_files/2` replaces rows on conflict, so a sync
  that found nothing changed still writes every row and bumps every timestamp.
  Keyed on `updated_at` this criterion could never pass — every scan would
  reconsider every component, which is the whole-project recompute the story
  exists to remove, arriving through the input that fires most often.

  ## Two families, not two siblings

  The control needs a component the change genuinely does not touch, and two
  siblings under one parent are not that. `expand_component_families/2` pulls
  in every component sharing a `parent_component_id` the moment one of them is
  stale — deliberately, because a parent's template emits its children's nodes
  and they are computed together. So a scenario built on `Catalog.Product` and
  `Catalog.Category` would assert against the family expansion rather than
  against file narrowing, and fail for a reason that is correct behaviour.

  Two contexts, each with its own child, gives two families. The change lands
  in one of them.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures

  @touched_spec ".code_my_spec/spec/users/account.spec.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A changed file costs the requirements that file answers" do
    scenario "one component's spec is edited and the project is scanned" do
      given_ :cross_context_dependency

      given_ "a graph that has been computed and served", context do
        # Twice, because `GraphWatcher.settle/1` answers `:ok` when it holds no
        # timer and cannot tell that from an announcement still in flight — so
        # the first read can return before the pass it should have waited for,
        # and that pass then lands during the baseline and stamps everything.
        _warm = read_settled_graph(context)
        _settled = read_settled_graph(context)

        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        before = read_settled_graph(context)
        cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)

        assert Enum.all?(freshness(before, context.users_child.id), fn {_name, at} ->
                 NaiveDateTime.compare(NaiveDateTime.from_iso8601!(at), cutoff) == :lt
               end),
               """
               The baseline is not backdated, so a pass ran while it was being
               taken and every row carries the current time. "Reconsidered" and
               "left alone" are then the same reading.

               baseline: #{inspect(freshness(before, context.users_child.id))}
               """

        {:ok, Map.put(context, :before, before)}
      end

      when_ "one component's spec file is edited and the project scans", context do
        # Rewritten to different content that is still *valid*, using the same
        # fixture the given wrote it with. A spec edited into invalidity would
        # move `spec_valid`'s verdict as well, and then "the requirements were
        # reconsidered" could be read off a changed answer rather than off the
        # file having changed — which is the claim.
        :ok =
          Fixtures.write_env_file(
            context.environment,
            @touched_spec,
            CodeMySpecSpex.GraphContentFixtures.child_spec("Users.Account",
              type: "schema",
              description: "Edited after the graph had been computed and served."
            )
          )

        :ok = Fixtures.scan_working_copy(context.scope)

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "the component whose spec it is gets reconsidered", context do
        refute freshness(context.after, context.users_child.id) ==
                 freshness(context.before, context.users_child.id),
               """
               A component's spec file changed and its requirements were not
               reconsidered.

               `spec_valid` is computed from that file's content. If the graph
               does not notice the edit, it goes on serving a verdict about a
               version of the file that no longer exists — and files are the
               observation this system takes most often, so it goes on doing so
               for every edit after it too.

               before: #{inspect(freshness(context.before, context.users_child.id))}
               after:  #{inspect(freshness(context.after, context.users_child.id))}
               """

        {:ok, context}
      end

      then_ "and a component in another family is left as it was", context do
        before_other = freshness(context.before, context.stories_child.id)
        after_other = freshness(context.after, context.stories_child.id)

        assert after_other == before_other,
               """
               Editing one component's spec reconsidered a component in a
               different context.

               That file answers nothing about this component — different
               module, different family, different tree. A scan that
               reconsiders it anyway is reconsidering everything, and the cost
               of an edit becomes the size of the project rather than the size
               of the change.

               before: #{inspect(before_other)}
               after:  #{inspect(after_other)}
               """

        {:ok, context}
      end
    end
  end

  defp freshness(graph, component_id) do
    (graph["nodes"] || [])
    |> Enum.filter(
      &(&1["entity_type"] == "component" and
          to_string(&1["entity_id"]) == to_string(component_id))
    )
    |> Enum.map(&{&1["name"], &1["checked_at"]})
    |> Enum.sort()
  end
end
