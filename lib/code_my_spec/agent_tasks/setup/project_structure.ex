defmodule CodeMySpec.AgentTasks.Setup.ProjectStructure do
  @moduledoc """
  Setup step: .code_my_spec/ directory structure exists.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.Environments

  def evaluate(scope, _task) do
    env = scope.environment
    base = CodeMySpec.Paths.base_dir()
    app_name = Helpers.extract_app_name(env)

    required =
      [base, Path.join(base, "rules"), Path.join(base, "spec")] ++
        if(app_name,
          do: [
            Path.join([base, "spec", app_name]),
            Path.join([base, "spec", "#{app_name}_web"])
          ],
          else: []
        )

    missing = Enum.reject(required, &Environments.file_exists?(env, &1))

    if missing == [],
      do: {:ok, :valid},
      else: {:ok, :invalid, "Missing directories: #{Enum.map_join(missing, ", ", &"`#{&1}`")}"}
  end

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
