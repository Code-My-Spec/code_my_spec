defmodule CodeMySpec.Provisioning.Tools.ProviderRequestTest do
  @moduledoc """
  The credential never appears in the tool's input or output — only in the
  header this module builds server-side — and a mutating call is refused
  without `confirm: true` so an agent cannot mutate a real account by
  constructing the wrong path on a whim.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Hetzner

  setup do
    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")
    %{scope: scope}
  end

  describe "execute/2" do
    test "a GET is unrestricted and never leaks the credential", %{scope: scope} do
      Req.Test.stub(Hetzner, fn conn ->
        refute Plug.Conn.get_req_header(conn, "authorization") == []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"servers" => []}))
      end)

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{provider: "hetzner", method: "GET", path: "/servers"}

      response =
        ToolLibrary.run(
          "provider_request",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      text = response_text(response)
      assert text =~ "servers"
      refute text =~ "test-token"
    end

    test "a mutating call without confirm is refused and never reaches the provider", %{
      scope: scope
    } do
      Req.Test.stub(Hetzner, fn _conn -> raise "should never be called" end)

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{provider: "hetzner", method: "DELETE", path: "/firewalls/1"}

      response =
        ToolLibrary.run(
          "provider_request",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "confirm: true"
    end

    test "a mutating call with confirm: true reaches the provider", %{scope: scope} do
      Req.Test.stub(Hetzner, fn conn ->
        assert conn.method == "DELETE"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{}))
      end)

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{provider: "hetzner", method: "DELETE", path: "/firewalls/1", confirm: true}

      response =
        ToolLibrary.run(
          "provider_request",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
    end

    test "refuses an unknown provider", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{provider: "not-a-real-provider", method: "GET", path: "/x"}

      response =
        ToolLibrary.run(
          "provider_request",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "unknown provider"
    end
  end

  defp response_text({_status, text}), do: text
end
