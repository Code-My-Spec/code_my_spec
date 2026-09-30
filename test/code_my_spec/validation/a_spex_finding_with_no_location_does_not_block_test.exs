defmodule CodeMySpec.Validation.ASpexFindingWithNoLocationDoesNotBlockTest do
  @moduledoc """
  A spex finding the runner could not place is advisory, not an orphan.

  d91436b7: sexy_spex 0.2.1's `fail_on_error_logs` failure carries no
  stacktrace and no spec file, so the reconciler stores `file_path: "unknown"`.
  No story resolves from that, and "an orphan blocks" refused metric_flow's QA
  agent at every turn end over 24 findings nobody could open.

  An orphan is a spex whose story link broke — a real file. A finding with no
  file has no link to break.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, ProblemsFixtures, UsersFixtures}

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Problems
  alias CodeMySpec.Validation

  @mine "lib/my_app/mine.ex"
  @orphan "test/spex/nobody_owns_this/criterion_1_spex.exs"

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    Configurations.get_or_create(scope)
    {:ok, _} = Configurations.update(scope, %{spex: :block_all})

    for path <- [@mine, @orphan] do
      File.mkdir_p!(Path.join(tmp, Path.dirname(path)))
      File.write!(Path.join(tmp, path), "defmodule M do\nend\n")
    end

    {:ok, _} = FileSync.sync(scope, base_dir: tmp)

    session = "sess-#{System.unique_integer([:positive])}"
    :ok = FileEdits.track_edit(session, @mine)

    %{scope: scope, session: session}
  end

  defp red(scope, path) do
    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: path,
      message: "1 error(s) logged during test execution: [error] SyncWorker",
      severity: :error,
      category: "spex"
    })

    fresh_analysis_runs_fixture(scope)
    Problems.list_project_problems(scope, severity: :error)
  end

  test "a finding with no location is not enforceable", %{scope: scope} do
    assert Validation.enforceable(scope, red(scope, "unknown")) == [],
           "no file means no story link to have broken; it is not an orphan"
  end

  test "an agent that edited something may stop over it", ctx do
    red(ctx.scope, "unknown")

    assert {:ok, _} = Validation.validate_stop(ctx.scope, nil, session_id: ctx.session),
           "spex is attribution-exempt, so nothing else would demote this"
  end

  test "a real path whose story does not resolve still blocks", ctx do
    problems = red(ctx.scope, @orphan)

    assert length(Validation.enforceable(ctx.scope, problems)) == 1,
           "a broken story link has to stay loud"

    assert {:error, _reason, _key} =
             Validation.validate_stop(ctx.scope, nil, session_id: ctx.session)
  end
end
