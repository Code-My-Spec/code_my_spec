defmodule CodeMySpec.StaticAnalysis.PipelineEnvironmentTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.StaticAnalysis.Pipeline
  alias CodeMySpec.Support.InMemoryEnvironment

  setup do
    %{scope: full_scope_fixture()}
  end

  test "missing explicit environment preserves compiler findings", %{scope: scope} do
    finding = finding("compiler")
    assert {:ok, [_]} = Problems.create_problems(scope, [finding])

    assert {:error, :no_environment} =
             Pipeline.compile(%{scope | cwd: nil}, environment: nil)

    assert [persisted] = Problems.list_project_problems(scope, source: "compiler")
    assert persisted.message == finding.message
  end

  test "missing explicit environment preserves analyzer findings", %{scope: scope} do
    finding = finding("credo")
    assert {:ok, [_]} = Problems.create_problems(scope, [finding])

    assert {:error, :no_environment} =
             Pipeline.run_analyzers(%{scope | cwd: nil}, [:credo], [], %{}, environment: nil)

    assert [persisted] = Problems.list_project_problems(scope, source: "credo")
    assert persisted.message == finding.message
  end

  test "compile uses an explicit environment when scope cwd is nil", %{scope: scope} do
    cwd = CodeMySpec.TempFile.owned_dir("pipeline_explicit_environment")
    environment = Environment.new(:local, cwd)
    output_file = Path.join(cwd, "diagnostics.jsonl")

    File.write!(Path.join(cwd, "mix.exs"), """
    defmodule PipelineEnvironmentProbe.MixProject do
      use Mix.Project

      def project do
        File.write!("compiled-in-explicit-environment", "yes")
        File.write!(System.fetch_env!("DIAGNOSTICS_OUTPUT"), "")
        [app: :pipeline_environment_probe, version: "0.1.0", compilers: []]
      end
    end
    """)

    assert :ok =
             Pipeline.compile(put_fixture_environment(scope, nil),
               environment: environment,
               compile_output_file: output_file
             )

    assert File.read!(Path.join(cwd, "compiled-in-explicit-environment")) == "yes"
  end

  test "QA validator reads from the selected environment, not fixture_environment(scope)", %{
    scope: scope
  } do
    path = ".code_my_spec/qa/1012/brief.md"

    local_content = """
    ## Tool
    Browser
    ## Auth
    Test account
    ## Seeds
    One story
    ## What To Test
    Submit a result
    ## Result Path
    .code_my_spec/qa/1012/result.md
    """

    File.mkdir_p!(Path.dirname(Path.join(fixture_environment(scope).cwd, path)))
    File.write!(Path.join(fixture_environment(scope).cwd, path), local_content)

    {1, [file]} =
      Files.upsert_files(scope, [
        %{path: path, role: :qa_brief, fingerprint: "qa-brief", valid: true}
      ])

    {:ok, selected_environment} = InMemoryEnvironment.create(working_dir: "/selected-copy")
    on_exit(fn -> InMemoryEnvironment.destroy(selected_environment) end)
    :ok = InMemoryEnvironment.write_file(selected_environment, path, "not a QA brief")

    assert :ok =
             Pipeline.run_analyzers(scope, [:validate_qa], [file], %{},
               environment: selected_environment
             )

    assert [%{source: "qa_validation", severity: :error}] =
             Problems.list_project_problems(scope, source: "qa_validation")
  end

  defp finding(source) do
    %{
      severity: :error,
      source_type: :static_analysis,
      source: source,
      file_path: "lib/example.ex",
      message: "existing finding",
      category: "test"
    }
  end
end
