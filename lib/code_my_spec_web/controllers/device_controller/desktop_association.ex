defmodule CodeMySpecWeb.DeviceController.DesktopAssociation do
  @moduledoc "Associates this desktop's previously accountless machine after account selection."
  alias CodeMySpec.Accounts.Authorization
  alias CodeMySpec.Devices
  alias CodeMySpec.UserPreferences.DesktopUser
  alias CodeMySpec.Users.Scope

  # The request UUID alone is not ownership proof. Only the desktop singleton,
  # matching the identity read from this server's own local harness file, may
  # associate its accountless local machine. Other devices keep normal scoping.
  def associate(%Scope{user: %{id: user_id}, active_account_id: account_id} = scope, requested_id)
      when is_binary(account_id) and is_binary(requested_id) do
    with true <- DesktopUser.active?(),
         %{user: %{id: ^user_id}} <- DesktopUser.scope(),
         true <- Authorization.authorize(:read_account, scope, account_id),
         ^requested_id <- CmsHarness.Device.recorded_id(),
         {:ok, id} <- Ecto.UUID.cast(requested_id) do
      Devices.associate_trusted_local_device(scope, id)
    end

    :ok
  end

  def associate(_scope, _requested_id), do: :ok
end
