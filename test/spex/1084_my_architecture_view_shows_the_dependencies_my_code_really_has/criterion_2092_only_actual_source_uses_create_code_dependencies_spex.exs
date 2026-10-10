defmodule CodeMySpecSpex.Story1084.Criterion2092Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 2092 — Only actual source uses create code dependencies.

  An alias and a module attribute name a component without using it. A remote
  call creates the observed dependency after the project syncs.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Only actual source uses create code dependencies", criterion: 2092 do
    scenario "an alias alone is ignored, then a remote call is recorded" do
      given_ "Billing and Accounts are designed, and Billing only names Accounts", context do
        app = ComponentGraphHelpers.app(context)
        ComponentGraphHelpers.design!(context, "#{app}.Billing")
        ComponentGraphHelpers.design!(context, "#{app}.Accounts")

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts
              @account_module Accounts
            end
            """
          )

        ComponentGraphHelpers.sync!(context)
        {:ok, context}
      end

      then_ "alias and config evidence do not create a dependency", context do
        section = billing_section(context)

        refute section =~ "Accounts",
               "expected no Accounts dependency from alias/config alone: #{section}"

        {:ok, context}
      end

      when_ "Billing makes a remote call and the project syncs", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts

              def charge(order), do: Accounts.fetch(order)
            end
            """
          )

        ComponentGraphHelpers.sync!(context)
        {:ok, context}
      end

      then_ "the call creates an observed code dependency", context do
        section = billing_section(context)
        marker = dependency_marker(section, "Accounts")
        assert marker, "expected an Accounts dependency marker in Billing's section: #{section}"
        assert marker =~ "in code", "expected the call to mark Accounts as in code: #{marker}"
        {:ok, context}
      end
    end
  end

  defp billing_section(context) do
    {:ok, _view, html} =
      live(context.conn, "/app/projects/#{context.project.id}/architecture/overview")

    component_section(html, "Billing")
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
