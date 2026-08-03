defmodule CodeMySpecSpex.Story124.Criterion5260Spex do
  @moduledoc """
  Story 124 — Project Setup
  Criterion 5260 — Interleaved completion still lands on 12/12.

  Order of step completion is not enforced. Satisfying steps interleaved
  across two halves still produces the fully-complete header.

  Surface: `/projects/:project_name/requirements/project_setup`.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Order of step completion is not enforced" do
    scenario "interleaved completion still lands on 12/12" do
      given_ "no steps are satisfied", context do
        Fixtures.reset_setup_env(context.environment)
        {:ok, context}
      end

      when_ "developer satisfies steps interleaved across two halves", context do
        steps = Fixtures.setup_steps()
        half = div(length(steps), 2)
        {first_half, second_half} = Enum.split(steps, half)

        # Zip-walk the halves, seeding one from each side per iteration.
        Enum.each(Enum.zip(first_half, second_half), fn {a, b} ->
          Fixtures.satisfy_setup_steps(context.scope, [a])
          Fixtures.satisfy_setup_steps(context.scope, [b])
        end)

        # Odd length — second_half has one extra. The drop is a no-op when
        # both halves are equal-length, so the extra-step path collapses to
        # an empty seed call (also a no-op) without branching.
        Fixtures.satisfy_setup_steps(
          context.scope,
          Enum.drop(second_half, length(first_half))
        )

        {:ok, context}
      end

      then_ "the project setup page shows all steps done", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/project_setup")

        assert render(view) =~ "Project Setup (12/12)"
        {:ok, Map.put(context, :view, view)}
      end
    end
  end
end
