defmodule CodeMySpecSpex.Story604.Criterion5375Spex do
  @moduledoc """
  Story 604 — Project creation from onboarding sets the project active
  and redirects to the app
  Criterion 5375 — Rule: module_name is auto-derived from the project
  name (multi-word title-cases each word and strips spaces).

  Observed via the public surface — after submitting "my project", the
  project's edit page shows module_name = "MyProject" in its input
  value.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import_givens CodeMySpecSpex.SharedGivens

  @input "my project"
  @expected_module_name "MyProject"

  spex "Multi-word name title-cases each word and strips spaces" do
    scenario "Submitting `my project` derives module_name MyProject" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit the project name", context do
        context.view
        |> form("#project_form", project: %{name: @input})
        |> render_submit()

        _target = assert_redirect(context.view)
        edit_html = fetch_edit_page_html!(recycle(context.conn), @input)

        {:ok, Map.put(context, :edit_html, edit_html)}
      end

      then_ "the module_name input on the edit page shows the derived value", context do
        assert context.edit_html =~ ~r{name="project\[module_name\]"[^>]*value="#{@expected_module_name}"} or
                 context.edit_html =~ ~r{value="#{@expected_module_name}"[^>]*name="project\[module_name\]"},
               "expected module_name input to have value=\"#{@expected_module_name}\" on the edit page"

        :ok
      end
    end
  end

  defp fetch_edit_page_html!(conn, project_name) do
    listing = get(conn, "/app/projects")
    listing_html = html_response(listing, 200)

    project_id =
      case Regex.run(~r{/app/projects/([0-9a-f-]+)[^"]*">[^<]*#{Regex.escape(project_name)}}, listing_html) do
        [_, id] ->
          id

        _ ->
          case Regex.run(~r{/app/projects/([0-9a-f-]+)}, listing_html) do
            [_, id] -> id
            _ -> raise "could not find project id for #{project_name} on /app/projects"
          end
      end

    edit = get(recycle(conn), "/app/projects/#{project_id}/edit")
    html_response(edit, 200)
  end
end
