defmodule CodeMySpecSpex.Story127.Criterion1634Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1634 — In a frozen project, a sync leaves an existing component's description, type and parent unchanged, even when its spec or code says otherwise.

  Components as records, step 4 (3aeb66cf): once a project is frozen, a sync
  stops treating its files as the description of its components. Surface:
  files written into the working copy, `sync_project`, `freeze_components`;
  observed through `get_component`, `list_components` and `show_architecture`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "In a frozen project, a sync leaves an existing component's description, type and parent unchanged, even when its spec or code says otherwise",
    criterion: 1634 do
    scenario "the spec is rewritten after the freeze" do
      given_ "a frozen project whose Accounts and Web have specs", context do
        app = app(context)
        spec!(context, "#{app}.Accounts", [], description: "Accounts, as specified")
        spec!(context, "#{app}.Web")
        sync!(context)
        freeze(context, write: true)
        {:ok, context}
      end

      when_ "Accounts' spec is rewritten with another type and description, and a sync runs",
            context do
        spec!(context, "#{app(context)}.Accounts", [],
          type: "module",
          description: "Something else"
        )

        sync!(context)
        {:ok, context}
      end

      then_ "Accounts is as it was", context do
        accounts = component(context, "#{app(context)}.Accounts")
        assert accounts["type"] == "context"
        assert accounts["description"] =~ "Accounts, as specified"
        assert accounts["parent_component_id"] == nil
        {:ok, context}
      end
    end
  end
end
