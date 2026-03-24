defmodule CodeMySpec.AgentTasks.Init.PhoenixProject do
  @moduledoc """
  Init step: verify a Phoenix project exists (mix.exs, lib/, config/).
  """

  def evaluate(scope, _session, _opts \\ []) do
    dir = working_dir(scope)
    mix_exs = Path.join(dir, "mix.exs")
    lib = Path.join(dir, "lib")
    config = Path.join(dir, "config")

    missing =
      [{mix_exs, "mix.exs"}, {lib, "lib/"}, {config, "config/"}]
      |> Enum.reject(fn {path, _} -> File.exists?(path) end)
      |> Enum.map(fn {_, name} -> name end)

    if missing == [],
      do: {:ok, :valid},
      else: {:ok, :invalid, "No Phoenix project at `#{dir}` — missing: #{Enum.join(missing, ", ")}"}
  end

  def command(_scope, _session, _opts \\ []) do
    {:ok, """
    # Create Phoenix Project

    ```bash
    mix phx.new . --app your_app_name
    ```

    Or in a new directory:
    ```bash
    mix phx.new your_app_name
    cd your_app_name
    ```

    After creation:
    ```bash
    mix deps.get
    mix ecto.create
    ```
    """}
  end

  defp working_dir(scope) do
    scope.cwd || File.cwd!()
  end
end
