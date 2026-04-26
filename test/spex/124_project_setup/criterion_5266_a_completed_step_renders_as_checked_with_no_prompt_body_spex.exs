defmodule CodeMySpecSpex.Story124.Criterion5266Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5266 — A completed step renders as checked with no prompt body.

  Progress is visible in the prompt: a completed step's name still
  appears, but its inline prompt heading is suppressed.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Progress is visible in the prompt" do
    scenario "a completed step renders with no prompt body" do
      given_ "only ApplicationInWeb is satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.satisfy_setup_steps(context.scope, [Setup.ApplicationInWeb])
        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "ApplicationInWeb's step name is rendered", context do
        assert render(context.view) =~ ProjectSetup.step_name(Setup.ApplicationInWeb)
        {:ok, context}
      end

      and_ "ApplicationInWeb's inline prompt heading is absent", context do
        heading = step_prompt_heading(Setup.ApplicationInWeb, context.scope)

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
