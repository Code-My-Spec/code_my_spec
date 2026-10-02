defmodule CodeMySpecSpex.Story127.Criterion1634Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1634 — A sync never changes an existing component's description, type or parent.

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

  spex "A sync never changes an existing component's description, type or parent",
    criterion: 1634 do
    scenario "Accounts' spec and code say something else" do
      given_ "Accounts and Web, designed", context do
        app = app(context)
        design!(context, "#{app}.Accounts", [], description: "Accounts, as designed")
        design!(context, "#{app}.Web")
        {:ok, context}
      end

      when_ "a spec gives Accounts another type and description, its code is written, and a sync runs",
            context do
        app = app(context)
        spec!(context, "#{app}.Accounts", [], type: "module", description: "Something else")
        implementation!(context, "#{app}.Accounts")
        sync!(context)
        {:ok, context}
      end

      then_ "Accounts is as it was designed", context do
        accounts = component(context, "#{app(context)}.Accounts")
        assert accounts["type"] == "context"
        assert accounts["description"] =~ "Accounts, as designed"
        assert accounts["parent_component_id"] == nil
        {:ok, context}
      end
    end
  end
end
