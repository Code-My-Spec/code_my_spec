defmodule CodeMySpecSpex.Story127.Criterion1629Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1629 — Freezing marks every unmarked dependency as authored.

  Components as records, step 3 (3aeb66cf): the one-time freeze that writes
  what each component is for into its record. Surface: `freeze_components`,
  observed through its report and `get_component`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Freezing marks every unmarked dependency as authored", criterion: 1629 do
    scenario "a spec declared a dependency" do
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
        {:ok, Map.put(context, :report, freeze(context, write: true))}
      end

      then_ "the dependency was marked, and nothing is left to mark", context do
        assert context.report =~ "edges to mark authored: 1"
        refute freeze(context) =~ "edges to mark authored"
        assert architecture(context) =~ edge(context, "Web", "Accounts")
        {:ok, context}
      end
    end
  end
end
