defmodule CodeMySpec.AgentTasks.Setup.Compilers do
  @moduledoc """
  Setup step: boundary and spex compilers configured in mix.exs.
  """

  alias CodeMySpec.AgentTasks.Setup.Context

  def check(%Context{} = ctx) do
    case Context.error(ctx, "mix.exs", :compilers, "`mix.exs` not synced") do
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
    # Configure Compilers

    Add a per-environment `compilers/1` to `mix.exs`:

    ```elixir
    def project do
      [compilers: compilers(Mix.env()), ...]
    end

    defp compilers(:test),
      do: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app]

    defp compilers(_),
      do: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :app]
    ```
    """}
  end
end
