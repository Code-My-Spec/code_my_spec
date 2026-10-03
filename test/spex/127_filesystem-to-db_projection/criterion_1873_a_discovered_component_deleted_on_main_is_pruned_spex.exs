defmodule CodeMySpecSpex.Story127.Criterion1873Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1873 — A discovered component whose module is no longer on main is pruned, even while a stale copy still has the file, unless an authored dependency or a story points at it.

  14f4f837: `SpecsPassingChecker` was deleted on main in v2.0.312 and stayed a
  requirement because a stale checkout still had the file. Surface: checkouts'
  harnesses delivering manifests; observed through `list_components`. The kept
  case (an authored dependency) is criterion 1637's.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers, only: [app: 1, listed: 1]

  import CodeMySpecSpex.HarnessedKnowledgeHelpers,
    only: [checkout: 2, manifest: 1, remove_code: 2, write_code: 3]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main deleting a module prunes its discovered component", criterion: 1873 do
    scenario "main deletes it, a stale copy still has it" do
      given_ "a main copy and a stale copy, both with the module, synced", context do
        main = checkout(context, main?: true)
        stale = checkout(context, [])
        module = "#{app(context)}.RetiredChecker"

        # Main keeps other code too: an empty checkout's manifest is refused.
        write_code(main, "lib/anchor.ex", "#{app(context)}.Anchor")

        for copy <- [main, stale] do
          write_code(copy, "lib/retired_checker.ex", module)
          manifest(copy)
        end

        context = Map.merge(context, %{main: main, stale: stale, module: module})

        assert listed(on(context, :main)) =~ module,
               "premise: main's module was not discovered, so its pruning proves nothing"

        {:ok, context}
      end

      when_ "main deletes the file and syncs", context do
        remove_code(context.main, "lib/retired_checker.ex")
        manifest(context.main)
        {:ok, context}
      end

      then_ "the component is gone, though the stale copy still has the file", context do
        refute listed(on(context, :main)) =~ context.module,
               "a component main deleted survived on a stale copy's file"

        {:ok, context}
      end
    end
  end

  defp on(context, copy), do: Map.put(context, :scope, Map.fetch!(context, copy).scope)
end
