defmodule CodeMySpecSpex.Story127.Criterion1636Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1636 — A module that code in a live checkout names and no component carries is created as discovered, under its nearest existing parent.

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

  spex "A module that code in a live checkout names and no component carries is created as discovered, under its nearest existing parent",
    criterion: 1636 do
    scenario "code for a module inside Accounts appears" do
      given_ "Accounts and Web, designed", context do
        app = app(context)
        design!(context, "#{app}.Accounts", [], description: "Accounts, as designed")
        design!(context, "#{app}.Web")
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
