defmodule CodeMySpecSpex.Story127.Criterion1652Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1652 — A sync reads no spec file; only implementation files in live checkouts count.

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

  spex "A sync reads no spec file; only implementation files in live checkouts count",
    criterion: 1652 do
    scenario "a spec and some code arrive together" do
      given_ "a spec for Billing and code for Invoices, neither designed", context do
        app = app(context)

        spec!(context, "#{app}.Billing", [],
          type: "context",
          description: "Billing, as specified"
        )

        implementation!(context, "#{app}.Invoices")
        {:ok, context}
      end

      when_ "a sync runs", context do
        sync!(context)
        {:ok, context}
      end

      then_ "Invoices is discovered, and the spec made nothing", context do
        app = app(context)
        assert component(context, "#{app}.Invoices")["provenance"] == "discovered"
        refute listed(context) =~ "#{app}.Billing"
        {:ok, context}
      end
    end
  end
end
