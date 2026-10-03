defmodule CodeMySpecSpex.Story127.Criterion1872Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1872 — A module that exists on a feature copy but not on main is not a requirement on any other copy.

  14f4f837: team 1's unpromoted `QueryTelemetry` was discovered from its copy
  and became `implementation_file` in team 2's story. The project's components
  come from main's code; a feature copy's module arrives when it is promoted.
  Surface: a checkout's harness delivering its manifest; observed through
  `list_components`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers, only: [app: 1, listed: 1]
  import CodeMySpecSpex.HarnessedKnowledgeHelpers, only: [checkout: 2, manifest: 1, write_code: 3]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A feature copy's unpromoted module is not the project's", criterion: 1872 do
    scenario "a feature copy writes a new module and syncs" do
      given_ "a main copy and a feature copy", context do
        main = checkout(context, main?: true)
        feature = checkout(context, [])
        {:ok, Map.merge(context, %{main: main, feature: feature})}
      end

      when_ "the feature copy writes a module main does not have, and both sync", context do
        module = "#{app(context)}.UnpromotedProbe"
        write_code(context.feature, "lib/unpromoted_probe.ex", module)
        manifest(context.feature)
        manifest(context.main)
        {:ok, Map.put(context, :module, module)}
      end

      then_ "no component exists for it, so no copy is asked to implement it", context do
        refute listed(Map.put(context, :scope, context.main.scope)) =~ context.module,
               "a module only a feature copy has became one of the project's components"

        {:ok, context}
      end
    end
  end
end
