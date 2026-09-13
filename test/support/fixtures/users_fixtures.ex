defmodule CodeMySpec.UsersFixtures do
  @moduledoc """
  Test data for `CodeMySpec.Users`.
  """

  import Ecto.Query
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Repo
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users
  alias CodeMySpec.Users.{Scope, User}
  alias CodeMySpec.WorkingCopies

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  @doc """
  Marks a user as having already done their first CLI connect — sets
  `users.cli_first_connected_at`. Used by analytics spex that
  exercise the "subsequent connect" branch of CliChannel.
  """
  def mark_cli_first_connected(%{id: user_id}) do
    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^user_id),
        set: [cli_first_connected_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    :ok
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
    Scope.for_user(user)
    |> Map.put(:active_account_id, account.id)
    |> Map.put(:active_account, account)
  end

  def user_scope_fixture(user, account, project) do
    scope =
      user_scope_fixture(user, account)
      |> Map.put(:active_project_id, project.id)
      |> Map.put(:active_project, project)

    # Files are keyed on the working copy that observed them — UNIQUE
    # (project_id, working_copy_id, path), working_copy_id NOT NULL — so any scope that
    # can write files needs one. A scope with a project stands in for something
    # serving a checkout of it, so minting here is what makes these fixtures
    # honest rather than a way around the constraint.
    #
    # The machine comes with it, for the same reason one level up: a checkout is
    # identified by {project, device, root}, `working_copies.device_id` is
    # NOT NULL, and a fixture that could mint a copy belonging to no machine
    # would be describing a state the product no longer has.
    {:ok, device} =
      CodeMySpec.Devices.announce(scope, nil, %{hostname: "test-machine", kind: :local})

    {:ok, harness} =
      WorkingCopies.issue(scope, nil,
        label: "the test harness for #{project.id}",
        device: device
      )

    %{scope | active_working_copy_id: harness.id}
  end

  def full_scope_fixture(project_attrs \\ %{}) do
    user = user_fixture()
    account = account_fixture()
    member_fixture(user, account)
    project = user_scope_fixture(user, account) |> project_fixture(project_attrs)

    # Anchor the test scope's environment to an isolated tmp dir. With a nil
    # cwd, Environments.Local.resolve_path/2 falls through to the BEAM's
    # working directory — i.e. the project root — and any code path under
    # test that writes through scope.environment leaks files into the live
    # tree (e.g. SpecStub.write_for_scope creating
    # .code_my_spec/spec/my_app/... which ComponentSync then re-projects
    # into the DB on the next sync).
    #
    # `TempFile` rather than `Briefly`, which every call to this fixture used
    # to go through. `Briefly.Entry.ensure_tmp/0` asks one GenServer for the
    # process's temp root with a hardcoded 5-second `GenServer.call` — no
    # option to raise it — so the most-used fixture in the suite was a
    # five-second bet on a single mailbox. On a box running three suites at
    # once it loses: `** (exit) exited in: GenServer.call(_, {:monitor, _},
    # 5000)` out of `full_scope_fixture`, recorded as a failure and blocking
    # every promotion until something re-ran the suite when the machine was
    # quieter. `TempFile.dir/1` touches no process at all.
    #
    # Cleanup registered here so it runs last — `on_exit` is LIFO, and this is
    # the first callback any test using this fixture registers, so anything
    # else tearing down still has its directory.
    tmp_dir = CodeMySpec.TempFile.dir("full_scope")
    File.mkdir_p!(tmp_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(tmp_dir) end)

    user_scope_fixture(user, account, project)
    |> Map.put(:environment, Environment.new(:local, tmp_dir))
  end

  def full_preferences_fixture do
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

  @doc """
  Backdates every login token belonging to the user with the given email by 31
  days, putting all magic links for that user past the verification window.

  Used by Spex scenarios that need an "expired magic link" precondition —
  there is no UI path that produces an expired token, so this is the
  approved test-only bridge.
  """
  def expire_magic_link_tokens_for(email) when is_binary(email) do
    dt = DateTime.add(DateTime.utc_now(:second), -31, :day)

    CodeMySpec.Repo.update_all(
      from(ut in Users.UserToken,
        join: u in Users.User,
        on: u.id == ut.user_id,
        where: u.email == ^email and ut.context == "login"
      ),
      set: [inserted_at: dt, authenticated_at: dt]
    )

    :ok
  end
end
