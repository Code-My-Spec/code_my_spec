defmodule CodeMySpecSpex.Story1062.Criterion3427Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3427 — A requirement records what it was computed from.

  Rule: a requirement's freshness is decided by the sources it was computed
  from, not by the project's.

  ## The claim is the record, not the recompute

  The other criteria on this rule are about what a pass *does* — 3472 that a
  changed finding moves the answer, 3473 that an unchanged one does not, 3424
  that an observation costs work in proportion to what it touched. All three
  are consequences of the same stored fact, and none of them asserts the fact
  exists.

  It is `inputs_fingerprint`, stamped per row by `Freshness.component/2` and
  `Freshness.story/2` and compared by `stale_entities/3` against what those
  sources hash to now. Everything incremental about this story rests on it, and
  until it was serialized it could not be read from outside at all — so the one
  thing every other criterion assumes was the one thing nothing checked.

  ## Per entity, which is the half the rule names

  "Not by the project's" is the operative clause. A single fingerprint over
  every input — which is what `GraphFingerprint.compute/2` is, one level up —
  makes every row equally stale the moment anything moves, and that is the
  whole-project recompute this story exists to remove. So the stamp has to
  differ between two entities whose sources differ, and an entity nothing
  touched has to keep the one it had while its neighbour's moves.

  A single-entity scenario cannot see that difference: one row's stamp changing
  is equally consistent with per-row provenance and with a project-wide hash
  written onto every row. Two entities, one observation, is the smallest shape
  that separates them.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @source "exunit"

  spex "Every requirement carries the sources it was computed from" do
    scenario "two components, and a finding recorded against one of them" do
      given_ :two_independent_sibling_schemas

      given_ "a test file for each sibling", context do
        for {component, path} <- [
              {context.sibling_a, "test/catalog/product_test.exs"},
              {context.sibling_b, "test/catalog/category_test.exs"}
            ] do
          :ok =
            Fixtures.write_env_file(
              context.environment,
              path,
              "defmodule #{component.module_name}Test do\n  use ExUnit.Case\nend\n"
            )
        end

        :ok = Fixtures.scan_working_copy(context.scope)

        _warm = read_settled_graph(context)
        _settled = read_settled_graph(context)

        {:ok, Map.put(context, :before, read_settled_graph(context))}
      end

      when_ "a test failure is recorded against the first sibling only", context do
        :ok =
          Fixtures.replace_problems(context.scope, context.sibling_a.id, @source, [
            %{
              message: "assertion failed",
              file_path: "test/catalog/product_test.exs",
              line: 7
            }
          ])

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "every requirement carries a fingerprint of its own sources", context do
        unstamped =
          (context.after["nodes"] || [])
          |> Enum.filter(&(&1["entity_type"] in ["component", "story"]))
          |> Enum.reject(& &1["inputs_fingerprint"])

        assert unstamped == [],
               """
               #{length(unstamped)} requirement(s) carry no record of what they
               were computed from.

               `stale_entities/3` decides whether to recompute a row by
               comparing this stamp against what that entity's sources hash to
               now. A row without one matches no fingerprint, so it is stale on
               every pass forever — and everything else on this story is built
               on the stamp being there.

               First few: #{unstamped |> Enum.take(3) |> Enum.map(&{&1["entity_name"], &1["name"]}) |> inspect()}
               """

        {:ok, context}
      end

      then_ "the component the finding landed on records a different one", context do
        assert stamp(context.after, context.sibling_a.id) !=
                 stamp(context.before, context.sibling_a.id),
               """
               A component's problems changed and its requirements still record
               the sources they were computed from before the change.

               The stamp is what `stale_entities/3` compares, so one that does
               not move is a row that will never be reconsidered — the answer
               freezes at whatever was true when it was last written.

               before: #{inspect(stamp(context.before, context.sibling_a.id))}
               after:  #{inspect(stamp(context.after, context.sibling_a.id))}
               """

        {:ok, context}
      end

      then_ "and its sibling, which nothing touched, records the same one", context do
        assert stamp(context.after, context.sibling_b.id) ==
                 stamp(context.before, context.sibling_b.id),
               """
               A finding recorded against one component moved the other
               component's record of what *it* was computed from.

               Nothing about this sibling changed. A stamp that moves anyway is
               not a record of this entity's sources — it is the project's,
               written onto every row, and every row is then equally stale the
               moment anything anywhere moves. That is the whole-project
               recompute this story exists to remove, surviving as a per-row
               field that only looks per-row.

               before: #{inspect(stamp(context.before, context.sibling_b.id))}
               after:  #{inspect(stamp(context.after, context.sibling_b.id))}
               """

        {:ok, context}
      end
    end
  end

  # One entity's stamp. Every requirement of an entity is stamped with the same
  # value — they read the same slice of the context and go stale together — so
  # this is a set, and a set with more than one member would itself be a defect.
  defp stamp(graph, entity_id) do
    (graph["nodes"] || [])
    |> Enum.filter(&(to_string(&1["entity_id"]) == to_string(entity_id)))
    |> Enum.map(& &1["inputs_fingerprint"])
    |> Enum.uniq()
    |> Enum.sort()
  end
end
