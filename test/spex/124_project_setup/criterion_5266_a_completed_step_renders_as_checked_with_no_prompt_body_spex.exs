defmodule CodeMySpecSpex.Story124.Criterion5266Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5266 — A completed step renders as checked with no prompt body.

  Progress is visible in the prompt: a completed step's name still
  appears, but its inline prompt heading is suppressed.

  Surface: `/app/projects/:project_id/setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Progress is visible in the prompt" do
    scenario "a completed step renders with no prompt body" do
      given_ "only ApplicationInWeb is satisfied", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(context.scope, [
          Fixtures.find_setup_step("application_in_web")
        ])

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "ApplicationInWeb's step name is rendered", context do
        assert render(context.view) =~
                 Fixtures.step_name(Fixtures.find_setup_step("application_in_web"))

        {:ok, context}
      end

      and_ "ApplicationInWeb's inline prompt heading is absent", context do
        heading =
          step_prompt_heading(Fixtures.find_setup_step("application_in_web"), context.scope)

        refute render(context.view) =~ heading,
               "expected ApplicationInWeb prompt heading #{inspect(heading)} to be absent when completed"

        {:ok, context}
      end
    end
  end

  defp step_prompt_heading(mod, scope) do
    {:ok, prompt} = mod.command(scope, %{})

    prompt
    |> String.split("\n", trim: true)
    |> Enum.find(fn line -> String.starts_with?(line, "# ") end)
    |> String.replace_prefix("# ", "")
  end
end
