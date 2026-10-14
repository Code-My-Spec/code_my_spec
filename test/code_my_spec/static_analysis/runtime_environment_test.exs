defmodule CodeMySpec.StaticAnalysis.RuntimeEnvironmentTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.StaticAnalysis.Analyzers.Credo
  alias CodeMySpec.StaticAnalysis.Analyzers.Sobelow
  alias CodeMySpec.StaticAnalysis.Runner
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  test "a selected working copy wins over stale scope cwd" do
    scope = working_copy_scope_fixture()
    selected_environment = WorkingCopies.environment(scope)
    File.mkdir_p!(Path.join(selected_environment.cwd, "deps/credo"))
    File.write!(Path.join(selected_environment.cwd, "mix.exs"), "# selected checkout")

    scope = %{scope | cwd: "/stale/path"}

    assert StaticAnalysis.resolve_environment([], scope, scope.cwd) == selected_environment
    assert Credo.available?(scope)
  end

  test "explicit nil environment is honored by resolution and run_all" do
    scope = %Scope{cwd: "/stale/local/path"}

    assert StaticAnalysis.resolve_environment([environment: nil], scope, scope.cwd) == nil
    assert {:error, :no_environment} = Runner.run_all(scope, environment: nil)
  end

  test "unresolved selected working copy does not fall back to stale cwd" do
    scope = %Scope{
      active_project_id: Ecto.UUID.generate(),
      active_working_copy_id: Ecto.UUID.generate(),
      cwd: "/stale/local/path"
    }

    assert StaticAnalysis.resolve_environment([], scope, scope.cwd) == nil
    assert {:error, :no_environment} = Runner.run_all(scope)
  end

  test "explicit environment overrides selected working copy" do
    environment = Environment.new(:local, "/chosen/runtime")

    scope = %Scope{
      active_project_id: Ecto.UUID.generate(),
      active_working_copy_id: Ecto.UUID.generate(),
      cwd: "/stale/local/path"
    }

    assert StaticAnalysis.resolve_environment([environment: environment], scope, scope.cwd) ==
             environment
  end

  test "analyzer availability checks the supplied runtime" do
    runtime_dir =
      Path.join(
        System.tmp_dir!(),
        "static_analysis_runtime_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(runtime_dir, "deps/credo"))
    File.mkdir_p!(Path.join(runtime_dir, "deps/sobelow"))
    File.write!(Path.join(runtime_dir, "mix.exs"), "defmodule Fixture.MixProject do end")
    on_exit(fn -> File.rm_rf!(runtime_dir) end)

    scope = %Scope{cwd: "/stale/path"}
    environment = Environment.new(:local, runtime_dir)

    assert Credo.available?(scope, environment: environment)
    assert Sobelow.available?(scope, environment: environment)
    refute Credo.available?(scope, environment: nil)
    refute Sobelow.available?(scope, environment: nil)
  end

  test "an analyzer returns no_environment without invoking a command" do
    scope = %Scope{cwd: "/stale/local/path"}

    assert {:error, :no_environment} = Credo.run_with_output(scope, environment: nil)
    assert {:error, :no_environment} = Sobelow.run_with_output(scope, environment: nil)
  end
end
