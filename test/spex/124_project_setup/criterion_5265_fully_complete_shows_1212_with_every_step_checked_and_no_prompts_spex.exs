defmodule CodeMySpecSpex.Story124.Criterion5265Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5265 — Fully complete shows 12/12 with every step checked and no prompts.

  Progress is visible in the prompt: when every step is satisfied, the
  header reads 12/12 and no inline prompt headings are rendered.

  Surface: `/app/projects/:project_id/setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Progress is visible in the prompt" do
    scenario "fully complete shows 12/12 with no prompt bodies" do
      given_ "every setup step is satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.satisfy_setup_steps(context.scope, Fixtures.setup_steps())
        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the header reads Project Setup (12/12)", context do
        assert render(context.view) =~ "Project Setup (12/12)"
        {:ok, context}
      end

      and_ "no incomplete prompt bodies are rendered", context do
        html = render(context.view)

        for mod <- Fixtures.setup_steps() do
          heading = step_prompt_heading(mod, context.scope)

          refute html =~ heading,
                 "expected inline prompt heading #{inspect(heading)} to be absent when fully complete"
        end

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
