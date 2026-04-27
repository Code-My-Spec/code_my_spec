defmodule CodeMySpecSpex.Story603.Criterion5372Spex do
  @moduledoc """
  Story 603 — Onboarding detects empty state and asks for a project name
  Criterion 5372 — Rule: The project-name field is required.

  Submitting it empty does not create a project; the user remains on
  /app/onboarding with feedback. Observed entirely through the LiveView
  surface — submitting the form, asserting the page still renders the
  input (not the redirected post-creation state) and shows a "required"
  validation message.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  spex "Submitting an empty project name does not create a project" do
    scenario "Submitting an empty project name does not create a project" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit the project-name form with an empty value", context do
        rendered =
          context.view
          |> form("#project_form", project: %{name: ""})
          |> render_submit()

        {:ok, Map.put(context, :rendered, rendered)}
      end

      then_ "the user remains on /app/onboarding", context do
        assert render(context.view) =~ ~r/(name|call).*?project/i or
                 render(context.view) =~ ~r/project.*?(name|call)/i,
               "expected to still be on the onboarding page (project-name prompt visible) " <>
                 "after submitting an empty value"

        :ok
      end

      then_ "the page shows feedback that the field is required", context do
        assert context.rendered =~ ~r/can't be blank|required|please.*name/i,
               "expected a 'required'/'can't be blank' message after empty submit, " <>
                 "got rendered HTML without expected feedback"

        :ok
      end
    end
  end
end
