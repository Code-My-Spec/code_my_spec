defmodule CodeMySpec.AgentTasks.Setup.SpexConfig do
  @moduledoc """
  Setup step: spex preferred_envs configured in mix.exs.
  """

  alias CodeMySpec.Environments

  def evaluate(scope, _task) do
    env = scope.environment

    case Environments.read_file(env, "mix.exs") do
      {:ok, content} ->
        if Regex.match?(~r/spex:\s*:test/, content),
          do: {:ok, :valid},
          else: {:ok, :invalid, "`spex: :test` not found in preferred_envs in `mix.exs`"}

      _ ->
        {:ok, :invalid, "Cannot read `mix.exs`"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Configure Spex

    Add to `cli/0` in `mix.exs`:

    ```elixir
    def cli do
      [preferred_envs: [spex: :test]]
    end
    ```
    """}
  end
end
