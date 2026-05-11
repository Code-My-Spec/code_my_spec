defmodule CodeMySpec.AccountsFixtures do
  alias CodeMySpec.Accounts.{Account, Member}
  alias CodeMySpec.Repo

  def valid_account_attributes(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    Enum.into(attrs, %{
      name: "Test Account #{unique_id}",
      slug: "test-account-#{unique_id}"
    })
  end

  def account_fixture(attrs \\ %{}) do
    Account.create_changeset(valid_account_attributes(attrs))
    |> Repo.insert!()
  end

  def valid_member_attributes(user, account, attrs \\ %{}) do
    Enum.into(attrs, %{
      user_id: user.id,
      account_id: account.id,
      role: :member
    })
  end

  def member_fixture(user, account, role \\ :member) do
    %Member{}
    |> Member.changeset(valid_member_attributes(user, account, %{role: role}))
    |> Repo.insert!()
  end

  def account_with_owner_fixture(user, attrs \\ %{}) do
    account = account_fixture(attrs)
    _member = member_fixture(user, account, :owner)
    account
  end
end
