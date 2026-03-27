defmodule CodeMySpec.AgentTasks.Setup.AppResources do
  @moduledoc """
  Setup step: framework knowledge, tools, and credo checks installed.
  """

  alias CodeMySpec.Environments

  @resource_dirs [:framework_dir, :tools_dir, :credo_checks_dir]

  def evaluate(scope, _task) do
    env = scope.environment

    missing =
      @resource_dirs
      |> Enum.reject(fn path_fn ->
        path = apply(CodeMySpec.Paths, path_fn, [])
        Environments.file_exists?(env, path)
      end)
      |> Enum.map(fn path_fn ->
        "`#{apply(CodeMySpec.Paths, path_fn, [])}`"
      end)

    if missing == [],
      do: {:ok, :valid},
      else: {:ok, :invalid, "Missing resource directories: #{Enum.join(missing, ", ")}"}
  end

  def command(_scope, _task) do
    {:ok, """
    # Install Framework Knowledge + Tools

    Use the `install_app_resources` tool to install framework reference files.

    This installs:
    - `.code_my_spec/framework/` — framework reference
    - `.code_my_spec/tools/` — helper scripts
    - `.code_my_spec/credo_checks/framework/` — custom Credo checks
    """}
  end
end
