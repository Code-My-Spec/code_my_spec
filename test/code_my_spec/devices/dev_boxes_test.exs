defmodule CodeMySpec.Devices.DevBoxesTest do
  @moduledoc """
  Story 1130: an owner or admin adds a dev box by choosing a provider; it gets a
  token of its own, kept only as a hash, that signs in as that box and no other.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Repo
  alias CodeMySpec.Workspaces.Runner

  setup do
    owner = user_fixture()
    account = account_with_owner_fixture(owner)
    %{scope: user_scope_fixture(owner, account)}
  end

  defp member_scope(scope, role) do
    user = user_fixture()
    account = scope.active_account
    _member = member_fixture(user, account, role)
    user_scope_fixture(user, account)
  end

  defp add(scope, params),
    do: Devices.add_dev_box(scope, params, Runner.dev_box(params["provider"]))

  describe "adding a dev box" do
    test "an owner adds one, and its provider says what kind of machine it is", %{scope: scope} do
      assert {:ok, %Device{} = box, token} =
               add(scope, %{
                 "name" => "cloud-1",
                 "provider" => "claude_code_cloud"
               })

      assert box.label == "cloud-1"
      assert box.provider == :claude_code_cloud
      assert box.kind == :cloud
      assert box.account_id == scope.active_account_id
      assert is_binary(token)

      assert {:ok, %Device{kind: :local}, _token} =
               add(scope, %{"name" => "laptop", "provider" => "local"})
    end

    test "only the token's hash is kept", %{scope: scope} do
      {:ok, box, token} =
        add(scope, %{"name" => "cloud-1", "provider" => "local"})

      stored = Repo.get!(Device, box.id)
      assert stored.token_hash != token
      refute inspect(stored) =~ token
    end

    test "an admin may add, a regular member may not", %{scope: scope} do
      assert {:ok, _box, _token} =
               scope
               |> member_scope(:admin)
               |> add(%{"name" => "by-admin", "provider" => "local"})

      assert {:error, :forbidden} =
               scope
               |> member_scope(:member)
               |> add(%{"name" => "by-member", "provider" => "local"})

      names = scope |> Devices.list_devices() |> Enum.map(& &1.label)
      assert "by-admin" in names
      refute "by-member" in names
    end

    test "an unknown provider or a blank name adds nothing", %{scope: scope} do
      assert {:error, :unknown_provider} =
               add(scope, %{"name" => "x", "provider" => "mainframe"})

      assert {:error, %Ecto.Changeset{}} =
               add(scope, %{"name" => "  ", "provider" => "local"})
    end
  end

  describe "signing in with a box's token" do
    test "it resolves to that box, marks it connected, and never to another", %{scope: scope} do
      {:ok, one, one_token} =
        add(scope, %{"name" => "one", "provider" => "local"})

      {:ok, two, two_token} =
        add(scope, %{"name" => "two", "provider" => "local"})

      assert one_token != two_token

      assert Repo.get!(Device, one.id).token_last_used_at == nil

      assert %Device{id: id} = Devices.sign_in_with_token(one_token)
      assert id == one.id
      assert Repo.get!(Device, one.id).token_last_used_at
      assert Repo.get!(Device, two.id).token_last_used_at == nil

      assert Devices.sign_in_with_token(two_token).id == two.id
    end

    test "a wrong or empty token resolves to nothing" do
      assert Devices.sign_in_with_token("cbt_nope") == nil
      assert Devices.sign_in_with_token("") == nil
      assert Devices.sign_in_with_token(nil) == nil
    end

    test "the account hears that the box connected", %{scope: scope} do
      :ok = Devices.subscribe(scope.active_account_id)
      {:ok, box, token} = add(scope, %{"name" => "one", "provider" => "local"})

      Devices.sign_in_with_token(token)

      assert_receive {:dev_box_connected, id}
      assert id == box.id
    end
  end

  describe "providers" do
    test "each is listed, found by id, and tells how to bring its box up with the token" do
      assert Enum.map(Runner.dev_boxes(), & &1.id()) == [:local, :claude_code_cloud]
      assert Runner.dev_box("local").label() == "Local"
      assert Runner.dev_box(:claude_code_cloud).label() == "Claude Code cloud"
      assert Runner.dev_box("mainframe") == nil

      context = %{token: "cbt_abc", server_url: "https://dev.example.com"}

      assert [%{key: "setup-local", body: body}] = Runner.dev_box("local").instructions(context)
      assert body =~ "cbt_abc"
      assert body =~ "cms"

      keys = Runner.dev_box("claude_code_cloud").instructions(context) |> Enum.map(& &1.key)
      assert keys == ["setup-script", "setup-hosts", "setup-network-secret"]
    end

    test "the cloud setup script carries no token and asks for no deploy key in the environment" do
      context = %{token: "cbt_abc", server_url: "https://dev.example.com"}
      sections = Runner.dev_box("claude_code_cloud").instructions(context)

      script = Enum.find(sections, &(&1.key == "setup-script")).body
      refute script =~ "cbt_abc"
      refute script =~ "CMS_DEPLOY_KEY"
      assert script =~ "https://dev.example.com"

      hosts = Enum.find(sections, &(&1.key == "setup-hosts")).body
      assert hosts =~ "dev.example.com"
      refute hosts =~ "httpbin.org"

      secret = Enum.find(sections, &(&1.key == "setup-network-secret")).body
      assert secret =~ "cbt_abc"
      assert secret =~ "no \"Bearer \""
    end
  end
end
