defmodule CodeMySpec.AgentTasks.Setup.AppResources do
  @moduledoc """
  Setup step: framework knowledge, tools, and credo checks installed.
  """

  @resource_dirs [:framework_dir, :tools_dir, :credo_checks_dir]

  def evaluate(scope, _task) do
    dir = scope.cwd || File.cwd!()

    missing =
      @resource_dirs
      |> Enum.reject(fn path_fn ->
        Path.join(dir, apply(CodeMySpec.Paths, path_fn, [])) |> File.dir?()
      end)
      |> Enum.map(fn path_fn ->
        "`#{Path.join(dir, apply(CodeMySpec.Paths, path_fn, []))}`"
      end)

    if missing == [],
      do: {:ok, :valid},
      else: {:ok, :invalid, "Missing resource directories: #{Enum.join(missing, ", ")}"}
  end

  def command(_scope, _task) do
    {:ok, """
    # Install Framework Knowledge + Tools

    ```bash
    curl -s -X POST http://localhost:4002/api/bootstrap/install-symlinks \\
      -H "Content-Type: application/json" \\
      -H "X-Working-Dir: $(pwd)"
    ```

    This installs:
    - `.code_my_spec/framework/` — framework reference
    - `.code_my_spec/tools/` — helper scripts
    - `.code_my_spec/credo_checks/framework/` — custom Credo checks
    """}
  end
end
