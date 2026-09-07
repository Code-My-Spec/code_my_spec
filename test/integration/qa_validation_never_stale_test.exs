defmodule CodeMySpec.Integration.QaValidationNeverStaleTest do
  @moduledoc """
  Regression test: a persisted `qa_validation` problem must never be
  reported as stale.

  `Run.@sources` (the `analysis_runs` ledger) only ever accepts
  `compiler`, `credo`, `exunit`, `spex` — `Run.changeset/2` rejects any
  other source with `validate_inclusion`. `qa_validation` and
  `spec_validation` are in-process document validators
  (`StaticAnalysis.Pipeline.run_validator/3`) that never write a ledger
  row at all, so a `RunsRepository.latest_completed_run/2` lookup for
  either source always misses.

  `Validation.check_blocking_problems/4` used to run every source that
  had persisted problems through `Analysis.fresh_sources/2`, including
  these two — folding "no ledger row exists" into "stale," forever,
  since none can ever be created. The stop response then named
  `qa_validation` as stale and told the agent stopping again "enqueues
  a rerun" — but `Analysis.ensure_stale_runs/3` never requests
  `qa_validation` or `spec_validation` (it only ever asks for
  `compiler`, `credo`, `exunit`, `spex`), so the promised rerun could
  never land and the same finding relabelled itself stale on every
  subsequent stop.

  Mirrors `Qa5091LiveTest`: real tmp dir, real scope, real
  `Validation.validate_stop/3` calls — no Fixtures bridge, no cassette.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Projects
  alias CodeMySpec.Validation
  alias Ecto.Adapters.SQL.Sandbox

  @broken_qa_brief_path ".code_my_spec/qa/9999/brief.md"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "a persisted qa_validation problem keeps blocking across stops without ever being labelled stale" do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    Configurations.get_or_create(scope)

    # block_all: the point of this test is what the stop response says about
    # a persisted finding, not whether block_changed's scope filter demotes
    # it — that is criterion 5109's job. Everything else is off so the only
    # source with a persisted problem is qa_validation.
    {:ok, _} =
      Configurations.update(scope, %{
        compile_warnings: :dont_block,
        exunit: :off,
        credo: :off,
        spex: :off,
        spec_validation: :off,
        qa_validation: :block_all
      })

    # Seed sync establishes a baseline with the broken brief still unwritten,
    # so the brief lands as a change `validate_stop`'s own
    # `FileSync.sync_changed/2` picks up on turn 1 — mirroring how
    # `Qa5091LiveTest` seeds before the file under test is written.
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/placeholder.ex"), "defmodule Placeholder do\nend\n")

    {:ok, sync1} = FileSync.sync(scope, base_dir: tmp_dir)
    assert sync1.changed_paths != [], "seed sync must emit changed paths"

    File.mkdir_p!(Path.join(tmp_dir, Path.dirname(@broken_qa_brief_path)))

    File.write!(Path.join(tmp_dir, @broken_qa_brief_path), """
    # QA Brief

    A stub qa brief missing required sections.
    """)

    compile_jsonl = Path.expand(Path.join(@fixture_dir, "compile.jsonl"))
    # `spex: :off` does not stop `spex_stale` from being requested — it is
    # deliberately absent from `@config_gated_analyzers`, since the
    # specs-passing gate needs a fresh run to exist regardless of whether a
    # failure blocks. Nothing here is about spex, so it has nothing to say.
    spex_jsonl = Path.expand("test/fixtures/validation/spex_green.jsonl")

    turn1 =
      Validation.validate_stop(scope, nil,
        compile_output_file: compile_jsonl,
        spex_output_file: spex_jsonl
      )

    assert {:error, reason1, _key} = turn1
    assert reason1 =~ "qa_validation", "turn 1 must persist and block on the broken brief"

    # Turn 2: no files changed. The qa_validation problem from turn 1 is
    # still on record and must still block — but it must never claim to be
    # stale, because nothing will ever run to un-stale it.
    turn2 =
      Validation.validate_stop(scope, nil,
        compile_output_file: compile_jsonl,
        spex_output_file: spex_jsonl
      )

    assert {:error, reason2, _key} = turn2

    assert reason2 =~ "qa_validation",
           "the finding is real and must keep blocking, got:\n#{reason2}"

    refute reason2 =~ "stale",
           "qa_validation has no ledger row and can never gain one — labelling it " <>
             "stale promises a rerun ensure_stale_runs/3 never requests, got:\n#{reason2}"
  end
end
