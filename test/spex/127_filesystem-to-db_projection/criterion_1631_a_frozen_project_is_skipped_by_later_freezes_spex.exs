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
    scenario "the freeze runs a second time" do
      given_ "Web and Accounts have specs, Web depending on Accounts, and Helper only code",
             context do
        app = app(context)
        spec!(context, "#{app}.Web", ["#{app}.Accounts"])
        spec!(context, "#{app}.Accounts")
        implementation!(context, "#{app}.Helper")
        sync!(context)
        {:ok, context}
      end

      given_ "the project is frozen", context do
        freeze(context, write: true)
        {:ok, context}
      end

      when_ "the freeze runs again", context do
        {:ok, Map.put(context, :report, freeze(context, write: true))}
      end

      # Since step 4 a frozen project's sync marks new code discovered itself,
      # so "changes nothing" is asked of what the first freeze wrote.
      then_ "it is skipped, and what the first freeze wrote is unchanged", context do
        app = app(context)
        assert context.report =~ "already frozen"
        assert component(context, "#{app}.Web")["provenance"] == "authored"
        assert component(context, "#{app}.Helper")["provenance"] == "discovered"
        {:ok, context}
      end
    end
  end
end
