defmodule CodeMySpec.Integration.Qa5091LiveTest do
  @moduledoc """
  Live QA for the Story 554 / criterion 5091 fix.

  Mirrors the 5091 spex scenario against the REAL filesystem (not the
  in-memory env spex use): byte-identical impl rewrite + new failing
  test, then drives `Validation.validate_stop` with cassette-style
  fixture outputs and asserts the response carries both a blocking
  compiler section AND an advisory exunit section.

  This is the regression test that would have caught the bug
  fingerprint-only `changed_paths` introduced — without the fix,
  exunit_stale never resolves (impl byte-identical → not in
  changed_paths → role :test → only :credo runs → no exunit
  problems → no advisory section).
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Projects
  alias CodeMySpec.Validation
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "byte-identical impl rewrite + new failing test surfaces both blocking compiler and advisory exunit" do
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

    {:ok, _} =
      Configurations.update(scope, %{
        compile_warnings: :block,
        exunit: :dont_block,
        credo: :off,
        spex: :off,
        spec_validation: :off,
        qa_validation: :off
      })

    impl = """
    defmodule ExampleContext do
      @moduledoc false
    end
    """

    spec = """
    # ExampleContext

    ## Type

    context

    QA stub.
    """

    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.mkdir_p!(Path.join(tmp_dir, ".code_my_spec/spec"))
    File.write!(Path.join(tmp_dir, "lib/example_context.ex"), impl)
    File.write!(Path.join(tmp_dir, ".code_my_spec/spec/example_context.spec.md"), spec)

    {:ok, sync1} = FileSync.sync(scope, base_dir: tmp_dir)
    assert sync1.changed_paths != [], "seed sync must emit changed paths"

    # Mimic the 5091 given_: rewrite impl with byte-identical content and
    # add a failing test. mtime advances because we re-write; fingerprint
    # is unchanged. Without the fix, sync_changed would drop impl from
    # changed_paths and exunit_stale would never resolve.
    Process.sleep(1100)
    File.write!(Path.join(tmp_dir, "lib/example_context.ex"), impl)

    File.write!(Path.join(tmp_dir, "test/example_context_test.exs"), """
    defmodule ExampleContextTest do
      use ExUnit.Case
      test "fails on purpose" do
        assert 1 == 2, "qa fixture failure"
      end
    end
    """)

    # Reuse the canonical fixtures used by the 5091 spex.
    fixture_dir =
      Path.expand("../fixtures/validation/pipeline_compile_block_exunit_advisory", __DIR__)

    compile_jsonl = Path.join(fixture_dir, "compile.jsonl")
    exunit_json = Path.join(fixture_dir, "exunit.json")

    result =
      Validation.validate_stop(scope, nil,
        compile_output_file: compile_jsonl,
        exunit_output_file: exunit_json,
        spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
      )

    assert {:error, reason, key} = result, "expected blocking response, got: #{inspect(result)}"
    assert is_binary(reason)

    assert is_binary(key),
           "the block carries a stable identity for the finding set — R8 counts repeats on " <>
             "this rather than on the reason text, which carries relative ages"

    assert reason =~ "Fix these problems before stopping:",
           "expected blocking header, got:\n#{reason}"

    assert reason =~ "compiler (1)",
           "expected compiler blocking section, got:\n#{reason}"

    assert reason =~ "lib/example_context.ex:2",
           "expected compiler warning detail, got:\n#{reason}"

    assert reason =~ "Additional problems",
           "expected advisory header (this is the regression), got:\n#{reason}"

    assert reason =~ ~r/exunit:\s*1\s/,
           "expected exunit advisory summary line, got:\n#{reason}"

    assert reason =~ "(advisory)",
           "expected (advisory) tag, got:\n#{reason}"
  end
end
