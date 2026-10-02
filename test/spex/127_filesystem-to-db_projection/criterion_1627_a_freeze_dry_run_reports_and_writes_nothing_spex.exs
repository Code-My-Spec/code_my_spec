defmodule CodeMySpecSpex.Story127.Criterion1627Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1627 — A freeze dry run reports, per project, the components it would mark authored and discovered, those already authored, the dependencies it would mark authored, and spec files that name no component, and it writes nothing.

  Components as records, step 3 (3aeb66cf): the one-time freeze that writes
  what each component is for into its record. Surface: `freeze_components`,
  observed through its report and `get_component`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A freeze dry run reports, per project, the components it would mark authored and discovered, those already authored, the dependencies it would mark authored, and spec files that name no component, and it writes nothing",
    criterion: 1627 do
    scenario "the project has an authored component as well" do
      given_ "Web and Accounts have specs, Web depending on Accounts, and Helper only code",
             context do
        app = app(context)
        spec!(context, "#{app}.Web", ["#{app}.Accounts"])
        spec!(context, "#{app}.Accounts")
        implementation!(context, "#{app}.Helper")
        sync!(context)
        {:ok, context}
      end

      given_ "an agent created Billing",
             context do
        CodeMySpecSpex.ComponentHelpers.create(context.scope,
          name: "Billing",
          module_name: "#{app(context)}.Billing",
          type: "context"
        )

        {:ok, context}
      end

      when_ "the freeze runs as a dry run", context do
        {:ok, Map.put(context, :report, freeze(context))}
      end

      then_ "it reports each count", context do
        app = app(context)
        assert context.report =~ "Would freeze"
        assert context.report =~ "authored: 2 (#{app}.Accounts, #{app}.Web)"
        assert context.report =~ "discovered: 1"
        assert context.report =~ "already authored: 1"
        assert context.report =~ "edges to mark authored: 1"
        assert context.report =~ "specs in a live checkout naming no component: none"
        {:ok, context}
      end

      then_ "and writes nothing", context do
        refute component(context, "#{app(context)}.Web")["provenance"] == "authored"
        assert freeze(context) =~ "Would freeze"
        {:ok, context}
      end
    end
  end
end
