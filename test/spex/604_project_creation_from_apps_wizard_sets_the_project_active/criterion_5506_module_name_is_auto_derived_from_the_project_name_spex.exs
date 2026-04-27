defmodule CodeMySpecSpex.Story604.Criterion5506Spex do
  @moduledoc """
  Story 604 — Project creation from /app's wizard sets the project active.
  Criterion 5506 — Rule: module_name is auto-derived from the submitted
  project name. Strip non-alphanumeric/non-space characters, title-case
  each word, remove spaces; fall back to "Project" + a short id when
  the result is empty.

  Four spex blocks (one ExUnit test each, fresh DB sandbox per spex)
  cover the derivation rules:
    - "my project"     → "MyProject"      (multi-word: title-case + strip spaces)
    - "fuellytics-app" → "FuellyticsApp"  (hyphenated: title-case each segment)
    - "3rd party tool" → "RdPartyTool"    (leading digits stripped per word)
    - "!!!"            → "Project<id>"    (no alphanumeric → fallback)

  Observed via the public surface — after submitting on /app, fetch the
  edit page for the created project and assert the module_name input's
  value matches the expected derived form.
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

  spex "Hyphenated name title-cases each segment as one word" do
    scenario "Submitting `fuellytics-app` derives module_name FuellyticsApp" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit `fuellytics-app`", context do
        submit_and_capture_edit_page(context, "fuellytics-app")
      end

      then_ "module_name input shows FuellyticsApp", context do
        assert_module_name(context.edit_html, "FuellyticsApp")
        {:ok, context}
      end
    end
  end

  spex "Leading number is stripped from derivation" do
    scenario "Submitting `3rd party tool` derives module_name RdPartyTool" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit `3rd party tool`", context do
        submit_and_capture_edit_page(context, "3rd party tool")
      end

      then_ "module_name input shows RdPartyTool", context do
        assert_module_name(context.edit_html, "RdPartyTool")
        {:ok, context}
      end
    end
  end

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

  defp assert_module_name(html, expected) do
    assert html =~
             ~r{name="project\[module_name\]"[^>]*value="#{expected}"} or
             html =~
               ~r{value="#{expected}"[^>]*name="project\[module_name\]"},
           "expected module_name input to have value=\"#{expected}\" on the edit page"
  end
end
