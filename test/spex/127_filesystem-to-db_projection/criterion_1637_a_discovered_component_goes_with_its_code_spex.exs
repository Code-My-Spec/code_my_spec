defmodule CodeMySpecSpex.Story127.Criterion1637Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1637 — A discovered component whose code is gone from every live checkout is removed by the next sync, unless an authored dependency or a story still points at it.

  Components as records (3aeb66cf): a sync reads no spec and writes nothing
  about an existing component; it only discovers what live code names and
  prunes what it discovered once the code is gone. Surface: files written into
  the working copy, `create_component`, `add_dependency`, `sync_project`;
  observed through `get_component`, `list_components` and `show_architecture`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A discovered component whose code is gone from every live checkout is removed by the next sync, unless an authored dependency or a story still points at it",
    criterion: 1637 do
    scenario "two discovered components lose their code, and Web depends on one" do
      given_ "Accounts and Web, designed", context do
        app = app(context)
        design!(context, "#{app}.Accounts", [], description: "Accounts, as designed")
        design!(context, "#{app}.Web")
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
