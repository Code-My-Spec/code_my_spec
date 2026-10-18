defmodule CodeMySpec.Provisioning.Tools.ReadDatabaseUrlTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Provisioning.Database

  setup do
    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    # The whole point: :server already minted and stored this credential in
    # ProjectSecrets before it ever reaches the local-filesystem write that a
    # project with no checkout on this side cannot complete — this reads the
    # value back rather than minting a second one nobody asked for.
    test "returns the connection string :server already minted", %{scope: scope} do
      {:ok, credential} = Database.credential(scope, "prod")

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{environment: "prod"}

      response =
        ToolLibrary.run(
          "read_database_url",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      assert response_text(response) == Database.url(credential)
    end
  end

  defp response_text({_status, text}), do: text
end
