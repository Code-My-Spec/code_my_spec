defmodule CodeMySpec.Accounts.AccountsRepositoryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Accounts.{Account, AccountsRepository, Member}
  alias CodeMySpec.Repo

  describe "create_account/1" do
    test "creates an account with valid attributes" do
      attrs = valid_account_attributes()

      assert {:ok, %Account{} = account} = AccountsRepository.create_account(attrs)
      assert account.name == attrs.name
      assert account.slug == attrs.slug
    end

    test "returns error with invalid attributes" do
      attrs = %{name: nil}

      assert {:error, changeset} = AccountsRepository.create_account(attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error with duplicate slug" do
      attrs = valid_account_attributes()
      {:ok, _account} = AccountsRepository.create_account(attrs)

      assert {:error, changeset} = AccountsRepository.create_account(attrs)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "returns error with reserved slug" do
      attrs = valid_account_attributes(%{slug: "admin"})

      assert {:error, changeset} = AccountsRepository.create_account(attrs)
      assert %{slug: ["is reserved and cannot be used"]} = errors_on(changeset)
    end
  end

  describe "get_account/1" do
    test "returns account when it exists" do
      account = account_fixture()

      assert fetched_account = AccountsRepository.get_account(account.id)
      assert fetched_account.id == account.id
      assert fetched_account.name == account.name
    end

    test "returns nil when account doesn't exist" do
      assert AccountsRepository.get_account(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_account!/1" do
    test "returns account when it exists" do
      account = account_fixture()

      assert fetched_account = AccountsRepository.get_account!(account.id)
      assert fetched_account.id == account.id
    end

    test "raises when account doesn't exist" do
      assert_raise Ecto.NoResultsError, fn ->
        AccountsRepository.get_account!(Ecto.UUID.generate())
      end
    end
  end

  describe "update_account/2" do
    test "updates account with valid attributes" do
      account = account_fixture()
      attrs = %{name: "Updated Name", slug: "updated-slug"}

      assert {:ok, updated_account} = AccountsRepository.update_account(account, attrs)
      assert updated_account.name == "Updated Name"
      assert updated_account.slug == "updated-slug"
    end

    test "returns error with invalid attributes" do
      account = account_fixture()
      attrs = %{name: ""}

      assert {:error, changeset} = AccountsRepository.update_account(account, attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error with duplicate slug" do
      account1 = account_fixture()
      account2 = account_fixture()

      assert {:error, changeset} =
               AccountsRepository.update_account(account2, %{slug: account1.slug})

      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "delete_account/1" do
    test "deletes account" do
      account = account_fixture()

      assert {:ok, deleted_account} = AccountsRepository.delete_account(account)
      assert deleted_account.id == account.id
      assert AccountsRepository.get_account(account.id) == nil
    end

    test "deletes account with associated members (cascade)" do
      user = user_fixture()
      account = account_with_owner_fixture(user)

      assert {:ok, deleted_account} = AccountsRepository.delete_account(account)
      assert deleted_account.id == account.id
      assert AccountsRepository.get_account(account.id) == nil

      assert Repo.get_by(Member, user_id: user.id, account_id: account.id) == nil
    end
  end

  describe "create_account_with_owner/2" do
    test "creates account and owner member in one transaction" do
      user = user_fixture()
      attrs = %{name: "My Account", slug: "my-account"}

      assert {:ok, %Account{} = account} =
               AccountsRepository.create_account_with_owner(user.id, attrs)

      assert account.name == "My Account"
      assert account.slug == "my-account"

      member = Repo.get_by(Member, user_id: user.id, account_id: account.id)
      assert member.role == :owner
    end

    test "returns error with invalid attributes" do
      user = user_fixture()
      attrs = %{name: "", slug: "invalid"}

      assert {:error, changeset} = AccountsRepository.create_account_with_owner(user.id, attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "auto-suffixes derived slug on collision instead of failing" do
      user_a = user_fixture()
      user_b = user_fixture()

      assert {:ok, first} =
               AccountsRepository.create_account_with_owner(user_a.id, %{name: "Acme"})

      assert first.slug == "acme"

      assert {:ok, second} =
               AccountsRepository.create_account_with_owner(user_b.id, %{name: "Acme"})

      assert second.name == "Acme"
      assert second.slug == "acme-2"
    end

    test "auto-suffix retries until an available slug is found" do
      user_a = user_fixture()
      user_b = user_fixture()
      user_c = user_fixture()
      user_d = user_fixture()

      assert {:ok, %{slug: "acme"}} =
               AccountsRepository.create_account_with_owner(user_a.id, %{name: "Acme"})

      assert {:ok, %{slug: "acme-2"}} =
               AccountsRepository.create_account_with_owner(user_b.id, %{name: "Acme"})

      assert {:ok, %{slug: "acme-3"}} =
               AccountsRepository.create_account_with_owner(user_c.id, %{name: "Acme"})

      assert {:ok, %{slug: "acme-4"}} =
               AccountsRepository.create_account_with_owner(user_d.id, %{name: "Acme"})
    end

    test "explicit slug is not auto-suffixed — collision returns an error" do
      user_a = user_fixture()
      user_b = user_fixture()

      assert {:ok, _} =
               AccountsRepository.create_account_with_owner(user_a.id, %{
                 name: "Acme",
                 slug: "my-explicit-slug"
               })

      assert {:error, changeset} =
               AccountsRepository.create_account_with_owner(user_b.id, %{
                 name: "Other",
                 slug: "my-explicit-slug"
               })

      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "by_slug/1" do
    test "returns query for accounts with matching slug" do
      account = account_fixture(%{slug: "test-slug"})

      query = AccountsRepository.by_slug("test-slug")
      [fetched_account] = Repo.all(query)
      assert fetched_account.id == account.id
    end

    test "returns empty result for non-existent slug" do
      query = AccountsRepository.by_slug("non-existent")
      assert [] = Repo.all(query)
    end
  end

  # These read whatever the unscoped query returns, so they assert against the
  # row they made rather than the first one back. A single row that escaped the
  # ExUnit sandbox and committed is permanent — the test database is created
  # once and reused — and this database holds exactly that: one account, one
  # user, one member with no test to own them. `[fetched] = Repo.all(query)`
  # then fails on arity, and `hd()` silently answers about a stranger.
  #
  # Same shape as bcad622d, which is about the analyzer's partition; nothing
  # truncates the one an agent's own `mix test` uses.
  describe "with_preloads/1" do
    test "returns query with specified preloads" do
      user = user_fixture()
      account = account_with_owner_fixture(user)

      query = AccountsRepository.with_preloads([:members])
      fetched_account = query |> Repo.all() |> Enum.find(&(&1.id == account.id))

      assert Ecto.assoc_loaded?(fetched_account.members)
      assert length(fetched_account.members) == 1
    end

    test "handles multiple preloads" do
      user = user_fixture()
      account = account_with_owner_fixture(user)

      query = AccountsRepository.with_preloads([:members, :users])
      fetched_account = query |> Repo.all() |> Enum.find(&(&1.id == account.id))

      assert Ecto.assoc_loaded?(fetched_account.members)
      assert Ecto.assoc_loaded?(fetched_account.users)
    end
  end
end
