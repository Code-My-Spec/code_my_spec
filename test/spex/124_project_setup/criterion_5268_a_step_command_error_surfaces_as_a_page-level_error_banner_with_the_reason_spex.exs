defmodule CodeMySpecSpex.Story124.Criterion5268Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5268 — A step command error surfaces as a page-level error banner with the reason.

  Step command errors propagate to the caller. A stub step whose
  `command/2` returns `{:error, :stub_explosion}` causes the page to
  render `[data-role=setup-error]` with the reason visible, instead of
  silently degrading.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Step command errors propagate to the caller" do
    scenario "step command error surfaces as a page-level error banner" do
      given_ "a stub erroring step is injected into the setup step list", context do
        Fixtures.reset_setup_env(context.environment)
        original = Application.get_env(:code_my_spec, :project_setup_steps)
        Application.put_env(:code_my_spec, :project_setup_steps, [Fixtures.erroring_setup_step()])

        on_exit(fn -> restore_project_setup_steps(original) end)

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the setup-error banner is visible", context do
        assert has_element?(context.view, "[data-role=setup-error]")
        {:ok, context}
      end

      and_ "the banner includes the error reason", context do
        assert render(context.view) =~ ":stub_explosion"
        {:ok, context}
      end
    end
  end

  defp restore_project_setup_steps(nil),
    do: Application.delete_env(:code_my_spec, :project_setup_steps)

  defp restore_project_setup_steps(value),
    do: Application.put_env(:code_my_spec, :project_setup_steps, value)
end
