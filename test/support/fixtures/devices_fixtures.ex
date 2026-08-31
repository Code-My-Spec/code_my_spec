defmodule CodeMySpec.DevicesFixtures do
  @moduledoc """
  A machine for a test to hang checkouts on.

  `working_copies.device_id` is `NOT NULL`: a checkout is identified by
  `{project, device, root}`, and one with no machine can neither be told apart
  from the same path elsewhere nor say whether it is running locally or in the
  cloud. So a test that mints a working copy needs a device the same way it
  needs a project, and this is the shortest honest way to get one.

  Through `Devices.announce/3` rather than a direct insert, because that is how
  a machine really arrives — and announcing twice with the same id recognises
  rather than duplicates, which is a property worth exercising by accident.
  """

  alias CodeMySpec.Devices

  @doc "A local machine on this scope's account."
  def device_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        hostname: "test-machine-#{System.unique_integer([:positive])}",
        kind: :local
      })

    {:ok, device} = Devices.announce(scope, nil, attrs)
    device
  end
end
