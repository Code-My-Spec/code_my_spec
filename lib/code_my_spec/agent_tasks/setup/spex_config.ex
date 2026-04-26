defmodule CodeMySpec.AgentTasks.Setup.SpexConfig do
  @moduledoc """
  Setup step: spex preferred_envs configured in mix.exs.
  """

  alias CodeMySpec.AgentTasks.Setup.Context

  def check(%Context{} = ctx) do
    case Context.error(ctx, "mix.exs", :spex_config, "`mix.exs` not synced") do
      nil -> :valid
      msg -> {:invalid, msg}
    end
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

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
