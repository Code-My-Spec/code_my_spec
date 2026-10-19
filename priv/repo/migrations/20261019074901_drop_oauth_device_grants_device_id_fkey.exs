defmodule CodeMySpec.Repo.Migrations.DropOauthDeviceGrantsDeviceIdFkey do
  use Ecto.Migration

  @moduledoc """
  `device_id` on `oauth_device_grants` is an opaque value, not a foreign
  key -- a device that has not yet announced itself should still be able to
  request a code. The migration this follows now creates the column
  without one; this drops it where an earlier, already-applied version
  left one behind. `IF EXISTS` because an environment that only ever saw
  the corrected version never had the constraint to drop.
  """

  def change do
    execute(
      "ALTER TABLE oauth_device_grants DROP CONSTRAINT IF EXISTS oauth_device_grants_device_id_fkey",
      ""
    )
  end
end
