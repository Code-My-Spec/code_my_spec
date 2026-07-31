defmodule CodeMySpec.Environments.NoEnvironmentTest do
  @moduledoc """
  Every file operation, and every task prompt, against no environment at all.

  This is the light harness's normal shape, not an edge case: the server has no
  working copy, so `scope.environment` is nil. Before these clauses existed the
  operations raised `FunctionClauseError`, which took out the prompt builders
  that call them — and a requirement whose prompt cannot be rendered cannot be
  worked at all. An agent hit that on nine requirements in a row and could get
  no further than a stack trace.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments

  describe "file operations with no environment" do
    test "reads, writes and stats answer instead of raising" do
      assert Environments.read_file(nil, "mix.exs") == {:error, :no_environment}
      assert Environments.list_directory(nil, "lib") == {:error, :no_environment}
      assert Environments.write_file(nil, "a.txt", "x") == {:error, :no_environment}
      assert Environments.delete_file(nil, "a.txt") == {:error, :no_environment}
      assert Environments.stat(nil, "mix.exs") == {:error, :no_environment}
      assert Environments.ensure_dir(nil, "lib") == {:error, :no_environment}
    end

    test "searches come back empty rather than exploding" do
      assert Environments.glob(nil, "**/*.ex") == []
      assert Enum.to_list(Environments.stream_files(nil, ["lib"])) == []
    end

    test "existence is false, which is not the same as absent" do
      # Documented asymmetry: fine for rendering a prompt, wrong for deciding a
      # requirement is unmet. A checker that needs the difference has to say so
      # itself — see Setup.Context.dir_status/2 and its :unobservable.
      refute Environments.file_exists?(nil, "mix.exs")
      refute Environments.exec_file_exists?(nil, "/usr/bin/mix")
    end

    test "a command reports failure rather than crashing the caller" do
      assert {_output, status} = Environments.cmd(nil, "mix", ["compile"], [])
      assert status != 0
    end
  end

  describe "task prompts on a server with no working copy" do
    setup do
      scope = full_scope_fixture()
      %{scope: %{scope | environment: nil}, task: %{}}
    end

    # The exact list an agent reported as crashing, each naming glob/2,
    # write_file/3 or list_directory/2 in its stack trace.
    for mod <- [
          CodeMySpec.AgentTasks.TechnicalStrategy,
          CodeMySpec.AgentTasks.CodeGeneration,
          CodeMySpec.AgentTasks.QaSetup,
          CodeMySpec.AgentTasks.QaIntegrationPlan,
          CodeMySpec.AgentTasks.QaJourney,
          CodeMySpec.AgentTasks.Release,
          CodeMySpec.AgentTasks.ArchitectureDesign
        ] do
      test "#{inspect(mod)}.command/2 renders", %{scope: scope, task: task} do
        assert {:ok, prompt} = unquote(mod).command(scope, task)

        assert is_binary(prompt) and prompt != "",
               "a requirement whose prompt cannot be built cannot be worked"
      end
    end
  end
end
