defmodule CodeMySpec.Notifications.PermissionRequestTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.PermissionRequest

  import CodeMySpec.UsersFixtures

  setup do
    scope = user_scope_fixture()
    %{scope: scope, user_id: scope.user.id}
  end

  describe "create_permission_request/2" do
    test "creates a pending permission request", %{user_id: user_id} do
      assert {:ok, %PermissionRequest{} = req} =
               Notifications.create_permission_request(user_id, %{
                 "tool_name" => "Bash",
                 "tool_input" => %{"command" => "echo hello"}
               })

      assert req.tool_name == "Bash"
      assert req.tool_input == %{"command" => "echo hello"}
      assert req.status == "pending"
      assert req.user_id == user_id
      assert req.decision == nil
    end

    test "fails without tool_name", %{user_id: user_id} do
      assert {:error, changeset} =
               Notifications.create_permission_request(user_id, %{
                 "tool_input" => %{}
               })

      assert %{tool_name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "resolve_permission_request/2" do
    test "resolves a pending request with allow", %{user_id: user_id} do
      {:ok, req} =
        Notifications.create_permission_request(user_id, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "ls"}
        })

      assert {:ok, resolved} = Notifications.resolve_permission_request(req.id, "allow")
      assert resolved.status == "approved"
      assert resolved.decision == "allow"
    end

    test "resolves a pending request with deny", %{user_id: user_id} do
      {:ok, req} =
        Notifications.create_permission_request(user_id, %{
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => "/tmp/test.txt"}
        })

      assert {:ok, resolved} = Notifications.resolve_permission_request(req.id, "deny")
      assert resolved.status == "denied"
      assert resolved.decision == "deny"
    end

    test "returns error for already resolved request", %{user_id: user_id} do
      {:ok, req} =
        Notifications.create_permission_request(user_id, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "ls"}
        })

      {:ok, _} = Notifications.resolve_permission_request(req.id, "allow")

      assert {:error, {:already_resolved, "approved"}} =
               Notifications.resolve_permission_request(req.id, "deny")
    end

    test "returns error for non-existent request" do
      assert {:error, :not_found} =
               Notifications.resolve_permission_request(Ecto.UUID.generate(), "allow")
    end

    test "broadcasts decision on PubSub", %{user_id: user_id} do
      {:ok, req} =
        Notifications.create_permission_request(user_id, %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "ls"}
        })

      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "permission_request:#{req.id}")

      {:ok, _} = Notifications.resolve_permission_request(req.id, "allow")

      assert_receive {:permission_decided, %{id: id, decision: "allow"}}
      assert id == req.id
    end
  end

  describe "get_permission_request/1" do
    test "returns the request by ID", %{user_id: user_id} do
      {:ok, req} =
        Notifications.create_permission_request(user_id, %{
          "tool_name" => "Read",
          "tool_input" => %{"file_path" => "/tmp/test.txt"}
        })

      fetched = Notifications.get_permission_request(req.id)
      assert fetched.id == req.id
      assert fetched.tool_name == "Read"
    end

    test "returns nil for non-existent ID" do
      assert is_nil(Notifications.get_permission_request(Ecto.UUID.generate()))
    end
  end
end
