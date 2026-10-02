defmodule CodeMySpecSpex.Story127.Criterion1638Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1638 — In a frozen project, an authored component is never removed by a sync, only by delete_component.

  Components as records, step 4 (3aeb66cf): once a project is frozen, a sync
  stops treating its files as the description of its components. Surface:
  files written into the working copy, `sync_project`, `freeze_components`;
  observed through `get_component`, `list_components` and `show_architecture`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "In a frozen project, an authored component is never removed by a sync, only by delete_component",
    criterion: 1638 do
    scenario "Accounts' spec and code are both deleted" do
      given_ "a frozen project whose Accounts and Web have specs", context do
        app = app(context)
        spec!(context, "#{app}.Accounts", [], description: "Accounts, as specified")
        spec!(context, "#{app}.Web")
        sync!(context)
        freeze(context, write: true)
        {:ok, context}
      end

      when_ "Accounts' spec is deleted and a sync runs", context do
        remove_spec!(context, "#{app(context)}.Accounts")
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
