defmodule CodeMySpecSpex.Story1084.Criterion1725Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 1725 — Sam sees a call between components that was just added.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam sees a call between components that was just added", criterion: 1725 do
    scenario "the architecture view shows the new in-code dependency" do
      given_ "Billing and Accounts are both designed contexts, and Billing's code now calls Accounts",
             context do
        design!(context, "Billing")
        design!(context, "Accounts")

        :ok =
          Environments.write_file(context.environment, "lib/billing.ex", """
          defmodule Billing do
            @moduledoc false
            alias Accounts
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

      then_ "it shows Billing depends on Accounts in the code", context do
        section = component_section(context.html, "Billing")

        marker = dependency_marker(section, "Accounts")
        assert marker, "expected a dependency marker next to Accounts in Billing's section: #{section}"
        assert marker =~ "in code", "expected Accounts to be marked as a code dependency, got: #{marker}"

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
    ~r/#{Regex.escape(module_name)}[^()]*\(([^)]*)\)/
    |> Regex.run(section_text)
    |> marker_from_match()
  end

  defp marker_from_match([_, marker]), do: marker
  defp marker_from_match(_), do: nil
end
