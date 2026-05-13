defmodule CodeMySpecSpex.Story604.Criterion5375Spex do
  @moduledoc """
  Story 604 — Project creation from /app's wizard sets the project active.
  Criterion 5375 — Multi-word project names title-case each word and
  strip the spaces when deriving `module_name`.

  Observed via the public surface — submit the project-name form on /app,
  then fetch the edit page for the created project and read the
  `module_name` input's rendered `value`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Multi-word name title-cases each word and strips spaces" do
    scenario "Submitting `my project` derives module_name MyProject" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit `my project`", context do
        submit_and_capture_edit_page(context, "my project")
      end

      then_ "module_name input shows MyProject", context do
        assert_module_name(context.edit_html, "MyProject")
        {:ok, context}
      end
    end
  end

  defp submit_and_capture_edit_page(context, name) do
    context.view
    |> form("#project_form", project: %{name: name})
    |> render_submit()

    _target = assert_redirect(context.view)
    edit_html = fetch_edit_page_html!(recycle(context.conn))

    {:ok, Map.put(context, :edit_html, edit_html)}
  end

  defp fetch_edit_page_html!(conn) do
    listing = get(conn, "/app/projects")
    listing_html = html_response(listing, 200)

    [_, project_id] =
      Regex.run(~r{/app/projects/([0-9a-f-]+)}, listing_html) ||
        raise "could not find any project on /app/projects"

    edit = get(recycle(conn), "/app/projects/#{project_id}/edit")
    html_response(edit, 200)
  end

  defp assert_module_name(html, expected) do
    assert html =~
             ~r{name="project\[module_name\]"[^>]*value="#{expected}"} or
             html =~
               ~r{value="#{expected}"[^>]*name="project\[module_name\]"},
           "expected module_name input to have value=\"#{expected}\" on the edit page"
  end
end
