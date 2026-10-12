defmodule CodeMySpec.Repo.Migrations.AMachineHoldsTheTunnelItsCopiesShare do
  @moduledoc """
  Story 1117: one tunnel per harness. The machine holds it, and every working
  copy on the machine gets an address on it. Cloudflare returns a tunnel's
  secret once, at creation, so it is stored here, encrypted.
  """

  use Ecto.Migration

  def change do
    alter table(:devices) do
      add :preview_tunnel_id, :string
      add :preview_tunnel_secret, :binary
    end
  end
end
