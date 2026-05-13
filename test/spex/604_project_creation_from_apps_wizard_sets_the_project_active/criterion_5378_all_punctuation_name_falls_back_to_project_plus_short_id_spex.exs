defmodule CodeMySpecSpex.Story604.Criterion5378Spex do
  @moduledoc """
  Story 604 — Project creation from /app's wizard sets the project active.
  Criterion 5378 — When the submitted project name has no alphanumeric
  characters (e.g. `!!!`), the derived `module_name` falls back to
  `Project` + a short id so the result is still a valid Elixir module name.

  Observed via the public surface — submit the project-name form on /app,
  then fetch the edit page and read the `module_name` input's `value`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "All-punctuation name falls back to Project + short id" do
    scenario "Submitting `!!!` produces a fallback Project + short-id module_name" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit `!!!`", context do
        submit_and_capture_edit_page(context, "!!!")
      end

      then_ "module_name input matches Project + short-id", context do
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
end
