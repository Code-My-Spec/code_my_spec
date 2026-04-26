defmodule CodeMySpecSpex.Story604.Criterion5377Spex do
  @moduledoc """
  Story 604 — Project creation from onboarding sets the project active
  and redirects to the app
  Criterion 5377 — Rule: module_name auto-derivation strips a leading
  number to produce a valid Elixir module name (must start with an
  uppercase letter).

  Observed via the public surface — submitting "3rd party tool"
  produces a project whose edit page shows module_name =
  "RdPartyTool".
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import_givens CodeMySpecSpex.SharedGivens

  @input "3rd party tool"
  @expected_module_name "RdPartyTool"

  spex "Leading number is stripped from derivation" do
    scenario "Submitting `3rd party tool` derives module_name RdPartyTool" do
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
        [_, id] -> id
        _ ->
          case Regex.run(~r{/app/projects/([0-9a-f-]+)}, listing_html) do
            [_, id] -> id
            _ -> raise "could not find project id for #{project_name}"
          end
      end

    edit = get(recycle(conn), "/app/projects/#{project_id}/edit")
    html_response(edit, 200)
  end
end
