defmodule CodeMySpecSpex.Story127.Criterion1636Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1636 — In a frozen project, a module that code names and no component carries is created as discovered, under its nearest existing parent by module name.

  Components as records, step 4 (3aeb66cf): once a project is frozen, a sync
  stops treating its files as the description of its components. Surface:
  files written into the working copy, `sync_project`, `freeze_components`;
  observed through `get_component`, `list_components` and `show_architecture`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "In a frozen project, a module that code names and no component carries is created as discovered, under its nearest existing parent by module name",
    criterion: 1636 do
    scenario "code for a module inside Accounts appears" do
      given_ "a frozen project whose Accounts and Web have specs", context do
        app = app(context)
        spec!(context, "#{app}.Accounts", [], description: "Accounts, as specified")
        spec!(context, "#{app}.Web")
        sync!(context)
        freeze(context, write: true)
        {:ok, context}
      end

      when_ "code for Accounts.Helper is written and a sync runs", context do
        implementation!(context, "#{app(context)}.Accounts.Helper")
        sync!(context)
        {:ok, context}
      end

      then_ "Accounts.Helper is discovered, under Accounts", context do
        app = app(context)
        helper = component(context, "#{app}.Accounts.Helper")
        assert helper["provenance"] == "discovered"
        assert helper["parent_component_id"] == component(context, "#{app}.Accounts")["id"]
        {:ok, context}
      end
    end
  end
end
