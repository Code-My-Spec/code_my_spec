defmodule CodeMySpec.CompileEnvironmentTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.Compile
  alias CodeMySpec.Environments.Environment

  setup do
    previous = Application.fetch_env(:code_my_spec, :environment)
    Application.put_env(:code_my_spec, :environment, CodeMySpec.Environments.Local)
    cwd = Path.join(System.tmp_dir!(), "compile-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)

    on_exit(fn ->
      File.rm_rf!(cwd)

      restore_environment(previous)
    end)

    %{cwd: cwd}
  end

  defp restore_environment({:ok, module}),
    do: Application.put_env(:code_my_spec, :environment, module)

  defp restore_environment(:error),
    do: Application.delete_env(:code_my_spec, :environment)

  test "the child Mix process keeps test mode and the analyzer build path", %{cwd: cwd} do
    # A dependency-free Mix project records the actual child environment. This
    # catches duplicate env entries whose last nil silently wins in System.cmd.
    File.write!(Path.join(cwd, "mix.exs"), """
    defmodule CompilerEnvironmentProbe.MixProject do
      use Mix.Project

      def project do
        File.write!("child-env", Atom.to_string(Mix.env()) <> "\\n" <>
          System.get_env("MIX_BUILD_PATH", "unset"))
        File.write!(System.fetch_env!("DIAGNOSTICS_OUTPUT"), "")
        [app: :compiler_environment_probe, version: "0.1.0", compilers: []]
      end
    end
    """)

    build_path = Path.join(cwd, "_build/analyzer")
    output_file = Path.join(cwd, "diagnostics.jsonl")

    result =
      Compile.execute(
        environment: Environment.new(:local, cwd),
        output_file: output_file,
        extra_env: [{"MIX_BUILD_PATH", build_path}]
      )

    assert result.exit_code == 0, result.output
    assert File.read!(Path.join(cwd, "child-env")) == "test\n#{build_path}"
    assert result.data.diagnostics_available
  end
end
