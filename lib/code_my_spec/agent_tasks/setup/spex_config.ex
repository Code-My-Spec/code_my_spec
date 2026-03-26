defmodule CodeMySpec.AgentTasks.Setup.SpexConfig do
  @moduledoc """
  Setup step: spex preferred_envs configured in mix.exs.
  """

  def evaluate(scope, _task) do
    dir = scope.cwd || File.cwd!()
    mix_exs = Path.join(dir, "mix.exs")

    case File.read(mix_exs) do
      {:ok, content} ->
        if Regex.match?(~r/spex:\s*:test/, content),
          do: {:ok, :valid},
          else: {:ok, :invalid, "`spex: :test` not found in preferred_envs in `#{mix_exs}`"}

      _ ->
        {:ok, :invalid, "Cannot read `#{mix_exs}`"}
    end
  end

  def command(scope, _task) do
    dir = scope.cwd || File.cwd!()

    {:ok, """
    # Configure Spex

    Add to `cli/0` in `#{Path.join(dir, "mix.exs")}`:

    ```elixir
    def cli do
      [preferred_envs: [spex: :test]]
    end
    ```
    """}
  end
end
