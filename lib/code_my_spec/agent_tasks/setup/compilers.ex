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

    Add a per-environment `compilers/1` to `mix.exs`, plus the `spex:` key
    that tells the `:spex` compiler where spec files live and which boundary
    owns them:

    ```elixir
    def project do
      [
        compilers: compilers(Mix.env()),
        spex: [pattern: "test/spex/**/*_spex.exs", boundary: <App>Spex],
        ...
      ]
    end

    # :spex only runs in :test — it compiles the BDD spec files under
    # test/spex, which exist in no other environment.
    defp compilers(:test),
      do: [:boundary, :diagnostics, :phoenix_live_view, :erlang, :elixir, :spex, :app]

    defp compilers(_),
      do: [:boundary, :diagnostics, :phoenix_live_view, :erlang, :elixir, :app]
    ```

    `:boundary` comes from the `:boundary` dep and `:diagnostics` from
    `:client_utils` — both must be present, and neither may be `only: :dev`,
    or the compiler is missing in `:test` and `:prod`.
    """}
  end
end
