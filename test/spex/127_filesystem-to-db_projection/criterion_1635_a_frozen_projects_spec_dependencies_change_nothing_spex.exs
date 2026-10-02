defmodule CodeMySpecSpex.Story127.Criterion1635Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1635 — In a frozen project, a spec's dependency list neither adds nor removes dependencies.

  Components as records, step 4 (3aeb66cf): once a project is frozen, a sync
  stops treating its files as the description of its components. Surface:
  files written into the working copy, `sync_project`, `freeze_components`;
  observed through `get_component`, `list_components` and `show_architecture`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "In a frozen project, a spec's dependency list neither adds nor removes dependencies",
    criterion: 1635 do
    scenario "after the freeze, Web's spec drops Accounts and lists Billing" do
      given_ "a frozen project where Web's spec listed Accounts", context do
        app = app(context)
        spec!(context, "#{app}.Web", ["#{app}.Accounts"])
        spec!(context, "#{app}.Accounts")
        spec!(context, "#{app}.Billing")
        sync!(context)
        assert architecture(context) =~ edge(context, "Web", "Accounts")
        freeze(context, write: true)
        {:ok, context}
      end

      when_ "Web's spec is rewritten to list Billing instead, and a sync runs", context do
        spec!(context, "#{app(context)}.Web", ["#{app(context)}.Billing"])
        sync!(context)
        {:ok, context}
      end

      then_ "the old dependency stays and the new one does not appear", context do
        assert architecture(context) =~ edge(context, "Web", "Accounts")
        refute architecture(context) =~ edge(context, "Web", "Billing")
        {:ok, context}
      end
    end
  end
end
