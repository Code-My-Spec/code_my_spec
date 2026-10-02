defmodule CodeMySpec.AppHealth do
  @moduledoc """
  Whether this app can serve: its database answers and has no migration
  pending. What a promote's reload checks before it calls the reload good —
  a reload that compiled but left a migration unrun is not one.

  Also reports whether a harness is connected for the checkout this server
  runs from. Reported only: a harness restarts after every promote, so a
  check that failed on it would fail every reload.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Analysis.HarnessRegistry, CodeMySpec.Repo],
    exports: :all

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Repo

  @type t :: %{
          healthy: boolean(),
          database: :ok | {:error, String.t()},
          pending_migrations: [integer()] | :unknown,
          harness_connected: boolean()
        }

  @spec check(String.t()) :: t()
  def check(root \\ File.cwd!()) do
    database = database()
    pending = if database == :ok, do: pending_migrations(), else: :unknown

    %{
      healthy: database == :ok and pending == [],
      database: database,
      pending_migrations: pending,
      harness_connected: HarnessRegistry.connected_at?(root)
    }
  end

  defp database do
    case Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp pending_migrations do
    for {:down, version, _name} <- Ecto.Migrator.migrations(Repo), do: version
  end
end
