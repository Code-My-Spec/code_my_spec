defmodule CodeMySpecWeb.ARefusedSocketSaysWhoTest do
  @moduledoc """
  A refused websocket upgrade names the caller and the credential.

  Issue `d96809d4`. A harness that cannot hold a socket retries on a backoff, so
  one bad credential becomes hundreds of identical refusals — 273 of them in one
  night, every line reading "connect refused — token not found" and naming
  neither the caller nor the key, while other keys connected fine in the same
  second. The operator chasing it read the *harness's* logs instead, which can
  only say that the far side said no, and filed the report without ever seeing
  the server's reason.

  Two things are asserted, and the second is the one that makes it safe:

    * the refusal identifies the credential well enough to match a suspected key
    * it does not contain the key

  A digest rather than a prefix, so a log that leaks is not a log that leaks
  credentials.

  The third is that "the key is unknown" and "the key is fine and its project has
  no owner" stopped being the same sentence. They send an operator to different
  places, and only one of them is about the credential at all.
  """

  use CodeMySpecTest.DataCase, async: true

  import ExUnit.CaptureLog

  import CodeMySpec.UsersFixtures

  alias CodeMySpecWeb.UserSocket

  defp digest_of(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  defp connect_info do
    %{peer_data: %{address: {127, 0, 0, 1}, port: 12_345}, user_agent: "cms-harness/2.0"}
  end

  defp refusal(token) do
    capture_log(fn ->
      assert :error = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, connect_info())
    end)
  end

  describe "an unknown credential" do
    test "is identified by a digest, not by its value" do
      token = "dk_#{Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}"

      log = refusal(token)

      assert log =~ "token not found"
      assert log =~ digest_of(token)

      refute log =~ token, """
      The refusal carries the credential itself. Logs are read, copied into
      issues and shipped off the machine; a digest identifies the key just as
      well and cannot be replayed.
      """
    end

    test "says its shape, because the two in use look nothing alike" do
      long = String.duplicate("a", 128)

      assert refusal(long) =~ "key=len128"
      assert refusal("dk_something") =~ "key=dk"
    end

    test "and says who was asking" do
      log = refusal("dk_whoever")

      assert log =~ "peer=127.0.0.1"
      assert log =~ "cms-harness/2.0"
    end
  end

  describe "a credential that is fine" do
    test "still connects, so the refusals above are refusing something real" do
      scope = full_scope_fixture()
      {:ok, project} = CodeMySpec.Projects.get_project(scope, scope.active_project_id)

      # The fixture makes its user a `:member`, not an `:owner`, so this project
      # has a valid deploy key and nobody to act as. The new message says that
      # outright; the old one called it "token not found", which is the first
      # thing this change caught and a reminder that the two failures send an
      # operator to different places.
      CodeMySpec.Repo.get_by!(CodeMySpec.Accounts.Member,
        user_id: scope.user.id,
        account_id: project.account_id
      )
      |> Ecto.Changeset.change(role: :owner)
      |> CodeMySpec.Repo.update!()

      assert {:ok, socket} =
               UserSocket.connect(
                 %{"token" => project.deploy_key},
                 %Phoenix.Socket{},
                 connect_info()
               )

      assert socket.assigns.deploy_key_project_id == project.id
    end
  end
end
