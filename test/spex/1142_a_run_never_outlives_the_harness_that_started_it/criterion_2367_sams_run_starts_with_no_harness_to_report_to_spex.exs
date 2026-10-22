defmodule CodeMySpecSpex.Story1142.Criterion2367Spex do
  @moduledoc """
  Story 1142 — A run never outlives the harness that started it.
  Criterion 2367 — Sam's run starts with no harness to report to.

  A run that cannot reach the harness it is meant to report to never runs
  a test: nobody would hear what it found, and nobody could stop it.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.Projects, only: [project_dir: 0]

  alias CmsHarnessTest.ClusteredProject

  spex "Sam's run starts with no harness to report to", criterion: 2367 do
    scenario "a run named for a harness that is not there" do
      given_ "a run is started for a harness that is not there", context do
        project = project_dir()
        :ok = ClusteredProject.make(project.root)

        {:ok, Map.put(context, :project, project)}
      end

      when_ "the run starts", context do
        {:ok,
         Map.put(context, :run, ClusteredProject.run_for_absent_harness(context.project.root))}
      end

      then_ "it stops at once without running any tests", context do
        refute context.run.ran?, "a test ran although no harness was there to report to"
        refute context.run.exit == 0, "the run reported success without a harness to report to"

        {:ok, context}
      end
    end
  end
end
