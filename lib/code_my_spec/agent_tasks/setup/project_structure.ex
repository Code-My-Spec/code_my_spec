defmodule CodeMySpec.AgentTasks.Setup.ProjectStructure do
  @moduledoc """
  Setup step: .code_my_spec/ directory structure exists.

  Directories aren't tracked as `File` records (FileSync syncs files), so
  this step is the one residual filesystem-bound check. The cost is at
  most a handful of `Environments.file_exists?/2` stats and only matters
  when the step is unsatisfied — once the dirs exist this returns fast.
  """

  alias CodeMySpec.AgentTasks.Setup.{Context, Helpers}

  def check(%Context{} = ctx) do
    base = CodeMySpec.Paths.base_dir()
    app = Context.app_name(ctx)

    required =
      [base, Path.join(base, "rules"), Path.join(base, "spec")] ++
        if app do
          [
            Path.join([base, "spec", app]),
            Path.join([base, "spec", "#{app}_web"])
          ]
        else
          []
        end

    missing = Enum.reject(required, &Context.dir_exists?(ctx, &1))

    if missing == [],
      do: :valid,
      else: {:invalid, "Missing directories: #{Enum.map_join(missing, ", ", &"`#{&1}`")}"}
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(scope, _task) do
    env = scope.environment
    app_name = Helpers.extract_app_name(env) || "your_app"
    base = CodeMySpec.Paths.base_dir()

    {:ok, """
    # Create Project Structure

    ```bash
    mkdir -p #{base}/rules #{base}/spec/#{app_name} #{base}/spec/#{app_name}_web
    ```
    """}
  end
end
