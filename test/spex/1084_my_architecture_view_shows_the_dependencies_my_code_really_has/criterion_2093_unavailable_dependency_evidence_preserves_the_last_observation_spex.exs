defmodule CodeMySpecSpex.Story1084.Criterion2093Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 2093 — Unavailable dependency evidence preserves the last observation.

  A source parse failure cannot prove an observed dependency disappeared. Once
  valid source is available again, the observation is refreshed while authored
  intent remains recorded.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Unavailable dependency evidence preserves the last observation", criterion: 2093 do
    scenario "a syntax error preserves observed edges until valid source returns" do
      given_ "Billing has an authored Accounts edge and code uses Accounts and Notifications",
             context do
        app = ComponentGraphHelpers.app(context)
        billing = ComponentGraphHelpers.design!(context, "#{app}.Billing")
        accounts = ComponentGraphHelpers.design!(context, "#{app}.Accounts")
        ComponentGraphHelpers.design!(context, "#{app}.Notifications")
        ComponentGraphHelpers.depend!(context, billing, accounts)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts
              alias #{app}.Notifications

              def charge(order) do
                Accounts.fetch(order)
                Notifications.notify(order)
              end
            end
            """
          )

        ComponentGraphHelpers.sync!(context)

        {:ok, context}
      end

      when_ "the source has a syntax error and sync runs", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts
              alias #{app}.Notifications

              def charge(order do
            end
            """
          )

        ComponentGraphHelpers.sync!(context)
        {:ok, context}
      end

      then_ "the last authored and observed evidence is retained", context do
        section = billing_section(context)
        accounts_marker = dependency_marker(section, "Accounts")
        notifications_marker = dependency_marker(section, "Notifications")

        assert accounts_marker, "expected the authored Accounts dependency: #{section}"

        assert accounts_marker =~ "planned",
               "expected Accounts to remain planned: #{accounts_marker}"

        assert accounts_marker =~ "in code",
               "expected the last Accounts observation: #{accounts_marker}"

        assert notifications_marker, "expected the last Notifications observation: #{section}"

        assert notifications_marker =~ "in code",
               "expected Notifications to remain marked in code: #{notifications_marker}"

        {:ok, context}
      end

      when_ "valid source returns without either remote call and sync runs", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts
            end
            """
          )

        ComponentGraphHelpers.sync!(context)
        {:ok, context}
      end

      then_ "the observed-only edge clears while the authored plan remains", context do
        section = billing_section(context)
        accounts_marker = dependency_marker(section, "Accounts")

        assert accounts_marker, "expected the authored Accounts edge to remain: #{section}"

        assert accounts_marker =~ "planned",
               "expected Accounts to remain planned: #{accounts_marker}"

        refute accounts_marker =~ "in code",
               "expected the no-call source to clear Accounts' code marker: #{accounts_marker}"

        refute section =~ "Notifications",
               "expected the observed-only Notifications edge to disappear: #{section}"

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
