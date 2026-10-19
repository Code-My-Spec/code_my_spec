defmodule CodeMySpec.Repo.Migrations.AddConsumedAtToOauthDeviceGrants do
  use Ecto.Migration

  @moduledoc """
  RFC 8628 §3.5: a device_code is single-use. Without this, every poll
  after approval answered the same access and refresh token for as long
  as the grant's own 10-minute window stood open.
  """

  def change do
    alter table(:oauth_device_grants) do
      add :consumed_at, :utc_datetime
    end
  end
end
