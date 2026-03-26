defmodule CodeMySpec.AgentTasks.Setup.Compilers do
  @moduledoc """
  Setup step: boundary and spex compilers configured in mix.exs.
  """

  def evaluate(scope, _task) do
    dir = scope.cwd || File.cwd!()
    mix_exs = Path.join(dir, "mix.exs")

    case File.read(mix_exs) do
      {:ok, content} ->
        has_boundary = Regex.match?(~r/compilers.*:boundary/s, content)
        has_spex = Regex.match?(~r/compilers.*:spex/s, content)

        if has_boundary and has_spex,
          do: {:ok, :valid},
          else: {:ok, :invalid, "Compilers not configured in `#{mix_exs}` (need :boundary and :spex)"}

      _ ->
        {:ok, :invalid, "Cannot read `#{mix_exs}`"}
    end
  end

  def command(scope, _task) do
    dir = scope.cwd || File.cwd!()

    {:ok, """
    # Configure Compilers

    Add a per-environment `compilers/1` to `#{Path.join(dir, "mix.exs")}`:

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
