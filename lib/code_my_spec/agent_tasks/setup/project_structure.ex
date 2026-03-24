defmodule CodeMySpec.AgentTasks.Setup.ProjectStructure do
  @moduledoc """
  Setup step: .code_my_spec/ directory structure exists.
  """

  def evaluate(scope, _session, _opts \\ []) do
    dir = scope.cwd || File.cwd!()
    base = Path.join(dir, CodeMySpec.Paths.base_dir())
    app_name = extract_app_name(dir)

    required =
      [base, Path.join(base, "rules"), Path.join(base, "spec")] ++
        if(app_name,
          do: [
            Path.join([base, "spec", app_name]),
            Path.join([base, "spec", "#{app_name}_web"])
          ],
          else: []
        )

    missing = Enum.reject(required, &File.dir?/1)

    if missing == [],
      do: {:ok, :valid},
      else: {:ok, :invalid, "Missing directories: #{Enum.map_join(missing, ", ", &"`#{&1}`")}"}
  end

  def command(scope, _session, _opts \\ []) do
    dir = scope.cwd || File.cwd!()
    app_name = extract_app_name(dir) || "your_app"
    base = CodeMySpec.Paths.base_dir()

    {:ok, """
    # Create Project Structure

    ```bash
    cd #{dir}
    mkdir -p #{base}/rules #{base}/spec/#{app_name} #{base}/spec/#{app_name}_web
    ```
    """}
  end

  defp extract_app_name(dir) do
    case File.read(Path.join(dir, "mix.exs")) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> nil
        end
      _ -> nil
    end
  end
end
