defmodule CodeMySpecSpex.Story1084.Criterion1728Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 1728 — Calls inside a context don't show as dependencies.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Calls inside a context don't show as dependencies", criterion: 1728 do
    scenario "an intra-context call is hidden while a cross-context call is shown" do
      given_ "Billing's code calls its own Invoice module, and also calls Accounts", context do
        design!(context, "Billing")
        design!(context, "Billing.Invoice", [], parent: "Billing", type: "schema")
        design!(context, "Accounts")

        :ok =
          Environments.write_file(context.environment, "lib/billing.ex", """
          defmodule Billing do
            @moduledoc false
            alias Billing.Invoice
            alias Accounts

            def charge(order) do
              Invoice.new(order)
              Accounts.fetch(order)
            end
          end
          """)

        sync!(context)
        {:ok, context}
      end

      when_ "Sam opens the architecture view", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/architecture/overview")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "no dependency is shown for the call to Billing's own Invoice module", context do
        section = component_section(context.html, "Billing")

        refute section =~ "Invoice",
               "expected the intra-context call to Invoice to be hidden: #{section}"

        {:ok, context}
      end

      then_ "a call from Billing to Accounts is shown", context do
        section = component_section(context.html, "Billing")

        assert section =~ "Accounts",
               "expected the cross-context call to Accounts to be shown: #{section}"

        {:ok, context}
      end
    end
  end

  defp component_section(html, name) do
    {_, _, prose_children} =
      html |> Floki.parse_document!() |> Floki.find(".prose") |> List.first()

    start_idx =
      Enum.find_index(prose_children, fn
        {"h3", _, _} = node -> Floki.text(node) == name
        _ -> false
      end)

    prose_children
    |> Enum.drop(start_idx + 1)
    |> Enum.take_while(fn
      {tag, _, _} -> tag not in ["h2", "h3"]
      _ -> true
    end)
    |> Floki.text()
  end
end
