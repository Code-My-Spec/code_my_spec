defmodule CodeMySpecSpex.Story127.Criterion1635Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1635 — A sync neither adds nor removes dependencies.

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

  spex "A sync neither adds nor removes dependencies",
    criterion: 1635 do
    scenario "Web's spec drops Accounts and lists Billing" do
      given_ "Web designed to depend on Accounts, and Billing designed beside them", context do
        app = app(context)
        design!(context, "#{app}.Accounts")
        design!(context, "#{app}.Billing")
        design!(context, "#{app}.Web", ["#{app}.Accounts"])
        {:ok, context}
      end

      when_ "Web's spec lists Billing and not Accounts, and a sync runs", context do
        assert architecture(context) =~ edge(context, "Web", "Accounts")
        spec!(context, "#{app(context)}.Web", ["#{app(context)}.Billing"])
        sync!(context)
        {:ok, context}
      end

      then_ "the designed dependency stays and the spec's does not appear", context do
        assert architecture(context) =~ edge(context, "Web", "Accounts")
        refute architecture(context) =~ edge(context, "Web", "Billing")
        {:ok, context}
      end
    end
  end
end
