defmodule CodeMySpecSpex.Story127.Criterion1631Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1631 — A frozen project is stamped and skipped by later freezes, so freezing twice changes nothing.

  Components as records, step 3 (3aeb66cf): the one-time freeze that writes
  what each component is for into its record. Surface: `freeze_components`,
  observed through its report and `get_component`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A frozen project is stamped and skipped by later freezes, so freezing twice changes nothing",
    criterion: 1631 do
    scenario "the freeze runs again after new code appears" do
      given_ "Web and Accounts have specs, Web depending on Accounts, and Helper only code",
             context do
        app = app(context)
        spec!(context, "#{app}.Web", ["#{app}.Accounts"])
        spec!(context, "#{app}.Accounts")
        implementation!(context, "#{app}.Helper")
        sync!(context)
        {:ok, context}
      end

      given_ "the project is frozen, then gains a module with only code", context do
        freeze(context, write: true)
        implementation!(context, "#{app(context)}.Later")
        sync!(context)
        {:ok, context}
      end

      when_ "the freeze runs again", context do
        {:ok, Map.put(context, :report, freeze(context, write: true))}
      end

      then_ "it is skipped, and the new module is not marked", context do
        assert context.report =~ "already frozen"

        refute component(context, "#{app(context)}.Later")["provenance"] in [
                 "authored",
                 "discovered"
               ]

        {:ok, context}
      end
    end
  end
end
