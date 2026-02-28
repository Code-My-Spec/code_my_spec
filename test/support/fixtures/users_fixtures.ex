defmodule CodeMySpec.UsersFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CodeMySpec.Users` context.
  """

  import Ecto.Query
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Users.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Users.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Users.login_user_by_magic_link(token)

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def user_scope_fixture(user, account) do
    # Set the active account for the user
    Scope.for_user(user)
    |> Map.put(:active_account_id, account.id)
    |> Map.put(:active_account, account)
  end

  def user_scope_fixture(user, account, project) do
    # Set the active account for the user
    user_scope_fixture(user, account)
    |> Map.put(:active_project_id, project.id)
    |> Map.put(:active_project, project)
  end

  def full_scope_fixture(project_attrs \\ %{}) do
    user = user_fixture()
    account = account_fixture()
    member_fixture(user, account)
    project = user_scope_fixture(user, account) |> project_fixture(project_attrs)

    user_scope_fixture(user, account, project)
    |> Map.put(:environment, Environment.new(:local, nil))
  end

  def full_preferences_fixture() do
    scope = full_scope_fixture()

    UserPreferences.create_user_preferences(scope, %{
      active_account_id: scope.active_account.id,
      active_project_id: scope.active_project.id
    })

    scope
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Users.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    CodeMySpec.Repo.update_all(
      from(t in Users.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Users.UserToken.build_email_token(user, "login")
    CodeMySpec.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    CodeMySpec.Repo.update_all(
      from(ut in Users.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
