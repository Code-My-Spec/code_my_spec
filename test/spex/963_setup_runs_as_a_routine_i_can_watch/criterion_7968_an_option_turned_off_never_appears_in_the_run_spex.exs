defmodule CodeMySpecSpex.Story963.Criterion7968Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7968 — An option turned off never appears in the run.

  The setup options are individual booleans, and the plan is derived
  from them: an option Sam has turned off contributes no step at all,
  rather than contributing a step that is skipped or greyed out. The
  run completes without it.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "An option turned off never appears in the run" do
    scenario "turning the email option off removes its step from the plan" do
      given_ "Sam has turned the email option off", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # The options form is `phx-change`, and its params are
        # `options[<key>]`. A submit carrying a `provisioning` map changed
        # nothing at all — the page kept every default and the criterion
        # passed while asserting the opposite of what it says.
        choose_all_setup_options_except(view, [:email])

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he opens the setup view", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "no email step appears in the sequence", context do
        # Anchor: the plan still renders other steps, so the refute below
        # is meaningful rather than passing on an empty page.
        assert has_element?(context.view, "[data-test='setup-step']"),
               "expected the plan to still render steps with email switched off"

        refute has_element?(context.view, "[data-test='setup-step'][data-step='email']"),
               "expected no email step in the plan when the email option is off"

        {:ok, context}
      end

      then_ "setup can complete without one", context do
        # The plan is complete in its own right: every step it does list is
        # eligible to run. Nothing is left in a blocked-on-email state.
        refute has_element?(context.view, "[data-test='setup-step'][data-state='blocked']"),
               "expected no step blocked on the absent email step"

        {:ok, context}
      end
    end
  end
end
