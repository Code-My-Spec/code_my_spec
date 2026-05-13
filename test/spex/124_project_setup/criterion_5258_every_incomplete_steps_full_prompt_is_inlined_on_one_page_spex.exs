defmodule CodeMySpecSpex.Story124.Criterion5258Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5258 — Every incomplete step's full prompt is inlined on one page.

  The prompt is self-contained: a developer (or agent) reading the
  setup page has every unchecked step's full instructions inline,
  without drilling elsewhere.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Prompt is self-contained" do
    scenario "every incomplete step's full prompt is inlined on one page" do
      given_ "ApplicationInWeb and CodemyspecDeps are satisfied; the rest are not", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.satisfy_setup_steps(context.scope, [
          Fixtures.find_setup_step("application_in_web"),
          Fixtures.find_setup_step("codemyspec_deps")
        ])

        {:ok, context}
      end

      when_ "developer views the project setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the page contains the inline prompt heading for every incomplete step", context do
        html = render(context.view)

        # TestSupportNamespace passes by default (missing conn_case.ex / data_case.ex
        # counts as "not wrong") — treat it as satisfied for this assertion.
        satisfied_by_fixture = [Fixtures.find_setup_step("application_in_web"), Fixtures.find_setup_step("codemyspec_deps")]
        satisfied_by_default = [Fixtures.find_setup_step("test_support_namespace")]

        incomplete =
          (Fixtures.setup_steps() -- satisfied_by_fixture) -- satisfied_by_default

        for mod <- incomplete do
          heading = step_prompt_heading(mod, context.scope)

          assert html =~ heading,
                 "expected inline prompt heading #{inspect(heading)} to be rendered for #{inspect(mod)}"
        end

        {:ok, context}
      end

      and_ "satisfied steps do not render their inline prompt heading", context do
        html = render(context.view)

        for mod <- [Fixtures.find_setup_step("application_in_web"), Fixtures.find_setup_step("codemyspec_deps")] do
          heading = step_prompt_heading(mod, context.scope)

          refute html =~ heading,
                 "expected inline prompt heading #{inspect(heading)} to be absent for completed #{inspect(mod)}"
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
