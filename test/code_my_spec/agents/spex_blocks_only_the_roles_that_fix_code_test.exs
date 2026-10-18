defmodule CodeMySpec.Agents.SpexBlocksOnlyTheRolesThatFixCodeTest do
  @moduledoc """
  A red spex on a latched story refuses a coding agent's stop, not a QA agent's.

  d91436b7: metric_flow's QA agent was refused at every turn end by spex it had
  no move to fix. `Validation.Menu` already holds problems only for the roles
  that fix code — John: "it shouldn't get blocked by problems" — and the gate
  ignored the role it was handed.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, DevicesFixtures, ProblemsFixtures}
  import CodeMySpec.{StoriesFixtures, UsersFixtures}

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria

  @mine "lib/my_app/mine.ex"
  @spex_path "test/spex/811_provisioning/criterion_6493_a_step_reports_its_provider_spex.exs"

  setup do
    tmp = CodeMySpec.TempFile.owned_dir("test")

    scope =
      put_fixture_environment(%{full_scope_fixture() | cwd: tmp}, Environment.new(:local, tmp))

    Configurations.get_or_create(scope)
    {:ok, _} = Configurations.update(scope, %{spex: :block_all})

    for path <- [@mine, @spex_path] do
      File.mkdir_p!(Path.join(tmp, Path.dirname(path)))
      File.write!(Path.join(tmp, path), "defmodule M do\nend\n")
    end

    {:ok, _} = FileSync.sync(scope, base_dir: tmp)

    story = story_fixture(scope)

    {:ok, _criterion} =
      AcceptanceCriteria.create_criterion(scope, story, %{
        description: "a step reports its provider",
        spec_path: @spex_path
      })

    {:ok, _} = Stories.set_specs_ready(scope, Stories.get_story(scope, story.id), true)

    problem_fixture(scope, %{source: "spex", severity: :error, file_path: @spex_path})
    fresh_analysis_runs_fixture(scope)

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  defp agent(ctx, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: false,
        working_copy: "/tmp/spex-role-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.copy.id
      })

    :ok = FileEdits.track_agent_edit(agent.id, @mine)
    agent
  end

  test "a QA agent that edited something is not refused", ctx do
    message = StopDecision.decide(ctx.scope, agent(ctx, "qa"))

    refute (message || "") =~ "Fix these problems",
           "QA has no move that clears a spex regression"
  end

  # a31f1cd6 step 4b, John: "main is NOT blocked on problems".
  test "a main agent that edited something is not refused", ctx do
    message = StopDecision.decide(ctx.scope, agent(ctx, "main"))

    refute (message || "") =~ "Fix these problems"
  end
end
