defmodule CodeMySpecSpex.Story124.Rule3OrderNotEnforcedSpex do
  @moduledoc """
  Story 124 — Project Setup
  Rule 3 — Order of step completion is not enforced.

  The checklist is state-based. A developer can satisfy steps in any
  order — reverse, interleaved, batched — and the final state renders
  identically.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Order of step completion is not enforced" do
    scenario "reverse-order completion still lands on 13/13" do
      given_ "no steps are satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        {:ok, context}
      end

      when_ "developer satisfies every step in reverse declaration order", context do
        reversed = Enum.reverse(ProjectSetup.setup_steps())

        for mod <- reversed do
          Fixtures.satisfy_setup_steps(context.environment, [mod])
        end

        {:ok, context}
      end

      then_ "the project setup page shows all steps done", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        assert render(view) =~ "Project Setup (13/13)"
        {:ok, Map.put(context, :view, view)}
      end
    end

    scenario "interleaved completion still lands on 13/13" do
      given_ "no steps are satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        {:ok, context}
      end

      when_ "developer satisfies steps interleaved across two halves", context do
        steps = ProjectSetup.setup_steps()
        half = div(length(steps), 2)
        {first_half, second_half} = Enum.split(steps, half)

        # Zip-walk the halves, seeding one from each side per iteration.
        Enum.each(Enum.zip(first_half, second_half), fn {a, b} ->
          Fixtures.satisfy_setup_steps(context.environment, [a])
          Fixtures.satisfy_setup_steps(context.environment, [b])
        end)

        # Odd length — second_half has one extra.
        if length(second_half) > length(first_half) do
          leftover = Enum.drop(second_half, length(first_half))
          Fixtures.satisfy_setup_steps(context.environment, leftover)
        end

        {:ok, context}
      end

      then_ "the project setup page shows all steps done", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/project_setup")

        assert render(view) =~ "Project Setup (13/13)"
        {:ok, Map.put(context, :view, view)}
      end
    end
  end
end
