defmodule CodeMySpecSpex.Story604.Criterion5378Spex do
  @moduledoc """
  Story 604 — Project creation from onboarding sets the project active
  and redirects to the app
  Criterion 5378 — Rule: module_name fallback. When the submitted name
  contains no alphanumeric characters, the derived module_name falls
  back to "Project" + a short id.

  Observed via the public surface — submitting "!!!" produces a
  project whose edit page shows a module_name matching
  "Project[A-Za-z0-9]+".
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  @input "!!!"

  spex "All-punctuation name falls back to Project + short id" do
    scenario "Submitting \"!!!\" produces a module_name matching Project + short id" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit the punctuation-only name", context do
        context.view
        |> form("#project_form", project: %{name: @input})
        |> render_submit()

        _target = assert_redirect(context.view)
        edit_html = fetch_edit_page_html!(recycle(context.conn), @input)

        {:ok, Map.put(context, :edit_html, edit_html)}
      end

      then_ "the module_name input has a fallback Project + short-id value", context do
        assert context.edit_html =~
                 ~r{name="project\[module_name\]"[^>]*value="Project[A-Za-z0-9]+"} or
                 context.edit_html =~
                   ~r{value="Project[A-Za-z0-9]+"[^>]*name="project\[module_name\]"},
               "expected module_name to match Project + short-id when the submitted " <>
                 "name has no alphanumeric characters"

        {:ok, context}
      end
    end
  end

  defp fetch_edit_page_html!(conn, _project_name) do
    listing = get(conn, "/app/projects")
    listing_html = html_response(listing, 200)

    # The submitted name "!!!" probably renders differently in HTML than
    # a normal name, so just grab the first project link in the listing.
    [_, project_id] =
      Regex.run(~r{/app/projects/([0-9a-f-]+)}, listing_html) ||
        raise "could not find any project on /app/projects"

    edit = get(recycle(conn), "/app/projects/#{project_id}/edit")
    html_response(edit, 200)
  end
end
