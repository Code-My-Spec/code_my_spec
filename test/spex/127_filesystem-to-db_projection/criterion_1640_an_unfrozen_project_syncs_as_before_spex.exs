defmodule CodeMySpecSpex.Story127.Criterion1640Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1640 — A project that has not been frozen syncs exactly as before.

  Components as records, step 4 (3aeb66cf): once a project is frozen, a sync
  stops treating its files as the description of its components. Surface:
  files written into the working copy, `sync_project`, `freeze_components`;
  observed through `get_component`, `list_components` and `show_architecture`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A project that has not been frozen syncs exactly as before", criterion: 1640 do
    scenario "a spec is rewritten in a project never frozen" do
      given_ "Accounts with a spec, synced", context do
        spec!(context, "#{app(context)}.Accounts", [], description: "Accounts, as specified")
        sync!(context)
        {:ok, context}
      end

      when_ "the spec is rewritten and a sync runs", context do
        spec!(context, "#{app(context)}.Accounts", [], description: "Accounts, rewritten")
        sync!(context)
        {:ok, context}
      end

      then_ "the component follows the spec", context do
        assert component(context, "#{app(context)}.Accounts")["description"] =~
                 "Accounts, rewritten"

        {:ok, context}
      end
    end
  end
end
