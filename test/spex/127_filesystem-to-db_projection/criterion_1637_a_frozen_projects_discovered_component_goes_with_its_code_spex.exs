defmodule CodeMySpecSpex.Story127.Criterion1637Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1637 — In a frozen project, a discovered component whose code is gone from every live checkout is removed by the next sync, unless an authored dependency or a story still points at it.

  Components as records, step 4 (3aeb66cf): once a project is frozen, a sync
  stops treating its files as the description of its components. Surface:
  files written into the working copy, `sync_project`, `freeze_components`;
  observed through `get_component`, `list_components` and `show_architecture`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "In a frozen project, a discovered component whose code is gone from every live checkout is removed by the next sync, unless an authored dependency or a story still points at it",
    criterion: 1637 do
    scenario "two discovered components lose their code, and Web depends on one" do
      given_ "a frozen project whose Accounts and Web have specs", context do
        app = app(context)
        spec!(context, "#{app}.Accounts", [], description: "Accounts, as specified")
        spec!(context, "#{app}.Web")
        sync!(context)
        freeze(context, write: true)
        {:ok, context}
      end

      given_ "code for Gone and for Kept, synced as discovered, and Web depending on Kept",
             context do
        app = app(context)
        implementation!(context, "#{app}.Gone")
        implementation!(context, "#{app}.Kept")
        sync!(context)

        depend!(
          context,
          CodeMySpecSpex.Fixtures.get_component_by_module_name(context.scope, "#{app}.Web"),
          CodeMySpecSpex.Fixtures.get_component_by_module_name(context.scope, "#{app}.Kept")
        )

        {:ok, context}
      end

      when_ "both files are deleted and a sync runs", context do
        remove_implementation!(context, "#{app(context)}.Gone")
        remove_implementation!(context, "#{app(context)}.Kept")
        sync!(context)
        {:ok, context}
      end

      then_ "Gone is removed, and Kept stays because Web points at it", context do
        refute listed(context) =~ "#{app(context)}.Gone"
        assert listed(context) =~ "#{app(context)}.Kept"
        {:ok, context}
      end
    end
  end
end
