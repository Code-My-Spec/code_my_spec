defmodule CodeMySpecSpex.Story1084.Criterion1727Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 1727 — Sam tells planned from actual at a glance.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam tells planned from actual at a glance", criterion: 1727 do
    scenario "a planned-and-coded dependency reads differently from a code-only one" do
      given_ "Sam planned Billing depending on Accounts, and the code also calls Notifications from Billing",
             context do
        billing = design!(context, "Billing")
        accounts = design!(context, "Accounts")
        design!(context, "Notifications")

        depend!(context, billing, accounts)

        :ok =
          Environments.write_file(context.environment, "lib/billing.ex", """
          defmodule Billing do
            @moduledoc false
            alias Accounts
            alias Notifications
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

      then_ "Billing to Accounts is marked planned and in code", context do
        section = component_section(context.html, "Billing")
        marker = dependency_marker(section, "Accounts")

        assert marker, "expected a dependency marker next to Accounts in Billing's section: #{section}"
        assert marker =~ "planned", "expected Accounts to be marked planned, got: #{marker}"
        assert marker =~ "in code", "expected Accounts to be marked in code, got: #{marker}"

        {:ok, context}
      end

      then_ "Billing to Notifications is marked in code only", context do
        section = component_section(context.html, "Billing")
        marker = dependency_marker(section, "Notifications")

        assert marker,
               "expected a dependency marker next to Notifications in Billing's section: #{section}"

        assert marker =~ "in code", "expected Notifications to be marked in code, got: #{marker}"
        refute marker =~ "planned", "expected Notifications not to be marked planned, got: #{marker}"

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

  defp dependency_marker(section_text, module_name) do
    case Regex.run(~r/#{Regex.escape(module_name)}[^()]*\(([^)]*)\)/, section_text) do
      [_, marker] -> marker
      _ -> nil
    end
  end
end
