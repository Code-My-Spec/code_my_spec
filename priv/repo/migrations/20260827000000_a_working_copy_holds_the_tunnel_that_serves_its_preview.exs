defmodule CodeMySpec.Repo.Migrations.AWorkingCopyHoldsTheTunnelThatServesItsPreview do
  use Ecto.Migration

  @moduledoc """
  Story 968. A working copy's preview answers on our zone, over a Cloudflare
  tunnel the checkout itself runs.

  Two columns rather than one because they are not the same kind of fact. The
  tunnel id is public — it is the CNAME target sitting in DNS, readable by
  anyone who resolves the name. The secret is the credential that lets a
  process claim to *be* that tunnel, and Cloudflare returns it exactly once, at
  creation. Lose it and the tunnel cannot be reconstructed, only replaced.

  So the secret is encrypted at rest like `projects.deploy_key`, and it is
  stored at all rather than re-fetched because there is nothing to re-fetch
  from.
  """

  def change do
    alter table(:working_copies) do
      add :preview_tunnel_id, :string
      add :preview_tunnel_secret, :binary
    end
  end
end
