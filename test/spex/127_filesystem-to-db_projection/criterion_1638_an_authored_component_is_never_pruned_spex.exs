defmodule CodeMySpecSpex.Story127.Criterion1638Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1638 — An authored component is never removed by a sync, only by delete_component.

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

  spex "An authored component is never removed by a sync, only by delete_component",
    criterion: 1638 do
    scenario "Accounts' spec and code are both deleted" do
      given_ "Accounts designed, with a spec and code, synced", context do
        app = app(context)
        design!(context, "#{app}.Accounts")
        spec!(context, "#{app}.Accounts")
        implementation!(context, "#{app}.Accounts")
        sync!(context)
        {:ok, context}
      end

      when_ "Accounts' spec and code are deleted and a sync runs", context do
        app = app(context)
        remove_spec!(context, "#{app}.Accounts")
        remove_implementation!(context, "#{app}.Accounts")
        sync!(context)
        {:ok, context}
      end

      then_ "Accounts is still there", context do
        assert listed(context) =~ "#{app(context)}.Accounts"
        {:ok, context}
      end
    end
  end
end
