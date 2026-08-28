defmodule CodeMySpec.McpServers.Devops.Tools.ImportAgeKeyTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Devops.Tools.ImportAgeKey
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Sops, Steps}
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  @moduletag :sops

  setup context do
    case Sops.available?() do
      false ->
        {:ok, skip: true}

      true ->
        scope = full_scope_fixture()
        {:ok, Map.merge(context, %{scope: scope, project: scope.active_project})}
    end
  end

  describe "execute/2" do
    # The reason this exists at all: a key generated on a real checkout this
    # server cannot reach still has to land here, under the exact name
    # ensure_age_key/3 would have used itself — or a later decrypt mints a
    # different key and every ciphertext already committed under the real
    # one becomes unreadable.
    test "stores the private key and confirms its derived public half", %{
      scope: scope,
      project: project
    } do
      {:ok, {public, private}} = Sops.generate_key()

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{project_id: project.id, environment: "prod", private_key: private}

      assert {:reply, response, ^frame} = ImportAgeKey.execute(params, frame)

      assert response.isError == false
      assert response_text(response) =~ public

      assert {:ok, ^private} =
               ProjectSecrets.fetch_value(scope, Steps.age_key_name("prod"))
    end

    test "refuses a key that is not actually an age key, rather than storing it", %{
      scope: scope,
      project: project
    } do
      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{project_id: project.id, environment: "prod", private_key: "not-a-real-key"}

      assert {:reply, response, ^frame} = ImportAgeKey.execute(params, frame)
      assert response.isError == true

      assert {:error, :not_found} =
               ProjectSecrets.fetch_value(scope, Steps.age_key_name("prod"))
    end

    test "refuses for a project that is not on this account", %{scope: scope} do
      {:ok, {_public, private}} = Sops.generate_key()

      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{
        project_id: "00000000-0000-0000-0000-000000000000",
        environment: "prod",
        private_key: private
      }

      assert {:reply, response, ^frame} = ImportAgeKey.execute(params, frame)
      assert response.isError == true
      assert response_text(response) =~ "no project"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
