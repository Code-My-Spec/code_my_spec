defmodule CodeMySpecSpex.Story127.Criterion1628Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1628 — Freezing marks every component named by a spec file in a live checkout as authored, and every other unmarked component as discovered.

  Components as records, step 3 (3aeb66cf): the one-time freeze that writes
  what each component is for into its record. Surface: `freeze_components`,
  observed through its report and `get_component`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Freezing marks every component named by a spec file in a live checkout as authored, and every other unmarked component as discovered",
    criterion: 1628 do
    scenario "two specs and one module with only code" do
      given_ "Web and Accounts have specs, Web depending on Accounts, and Helper only code",
             context do
        app = app(context)
        spec!(context, "#{app}.Web", ["#{app}.Accounts"])
        spec!(context, "#{app}.Accounts")
        implementation!(context, "#{app}.Helper")
        sync!(context)
        {:ok, context}
      end

      when_ "the freeze runs", context do
        freeze(context, write: true)
        {:ok, context}
      end

      then_ "the spec-named components are authored and the other is discovered", context do
        app = app(context)
        assert component(context, "#{app}.Web")["provenance"] == "authored"
        assert component(context, "#{app}.Accounts")["provenance"] == "authored"
        assert component(context, "#{app}.Helper")["provenance"] == "discovered"
        {:ok, context}
      end
    end
  end
end
