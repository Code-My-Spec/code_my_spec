defmodule CodeMySpec.OauthDeviceGrantTest do
  @moduledoc """
  Issue 94cb8e04 -- John's decision: a harness authenticates as its own
  OAuth client via the device authorization grant (RFC 8628). This covers
  the server-side flow: requesting a device code, a person deciding it,
  and the client polling for the result.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.OauthFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Oauth

  setup do
    %{application: oauth_application_fixture(), user: user_fixture()}
  end

  describe "request_device_code/3" do
    test "issues a pending grant with both codes set", %{application: application} do
      device_id = Ecto.UUID.generate()
      assert {:ok, grant} = Oauth.request_device_code(application.uid, device_id)

      assert is_binary(grant.device_code) and byte_size(grant.device_code) > 20
      assert grant.user_code =~ ~r/^[A-Z2-9]{4}-[A-Z2-9]{4}$/
      assert grant.device_id == device_id
      assert grant.interval == 5
      assert DateTime.compare(grant.expires_at, DateTime.utc_now()) == :gt
      refute Oauth.DeviceGrant.approved?(grant)
      refute Oauth.DeviceGrant.denied?(grant)
    end

    test "refuses an unregistered client" do
      assert {:error, :invalid_client} =
               Oauth.request_device_code("no-such-client", Ecto.UUID.generate())
    end

    test "a malformed device_id is an ordinary changeset error, not a crash", %{
      application: application
    } do
      assert {:error, changeset} =
               Oauth.request_device_code(application.uid, "qa-device-grant-test-device")

      assert "is not a valid id" in errors_on(changeset).device_id
    end

    test "two requests for the same client never collide on either code", %{
      application: application
    } do
      {:ok, first} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())
      {:ok, second} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())

      refute first.device_code == second.device_code
      refute first.user_code == second.user_code
    end
  end

  describe "get_device_grant_by_user_code/1" do
    test "finds the grant regardless of case or surrounding whitespace", %{
      application: application
    } do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())

      assert %{id: id} =
               Oauth.get_device_grant_by_user_code(" #{String.downcase(grant.user_code)} ")

      assert id == grant.id
    end

    test "answers nil for a code nothing issued" do
      assert Oauth.get_device_grant_by_user_code("ZZZZ-ZZZZ") == nil
    end
  end

  describe "decide_device_grant/3" do
    test "approving mints a token bound to the user and the application", %{
      application: application,
      user: user
    } do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())

      assert {:ok, decided} = Oauth.decide_device_grant(grant, user, :approve)
      assert decided.resource_owner_id == user.id
      assert is_integer(decided.access_token_id)

      token = CodeMySpec.Repo.get(CodeMySpec.Oauth.AccessToken, decided.access_token_id)
      assert token.resource_owner_id == user.id
      assert token.application_id == application.id

      refute is_nil(token.refresh_token),
             "John's decision (point 3): the harness keeps a refresh token bound to its own " <>
               "client. With none, a harness would need re-approval on every token's own expiry."
    end

    test "denying sets denied_at and mints nothing", %{application: application, user: user} do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())

      assert {:ok, decided} = Oauth.decide_device_grant(grant, user, :deny)
      assert decided.denied_at
      assert decided.access_token_id == nil
    end

    test "a second decision on an already-approved grant is refused", %{
      application: application,
      user: user
    } do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())
      {:ok, approved} = Oauth.decide_device_grant(grant, user, :approve)

      assert {:error, :already_decided} = Oauth.decide_device_grant(approved, user, :deny)
    end

    test "an expired grant cannot be decided", %{application: application, user: user} do
      {:ok, grant} =
        Oauth.request_device_code(application.uid, Ecto.UUID.generate(), ttl_seconds: -1)

      assert {:error, :expired} = Oauth.decide_device_grant(grant, user, :approve)
    end
  end

  describe "revoke_device_authorization/2" do
    test "revocation blocks access, refresh, and an unconsumed device code" do
      scope = full_scope_fixture()
      device = CodeMySpec.DevicesFixtures.device_fixture(scope)
      application = oauth_application_fixture()
      {:ok, grant} = Oauth.request_device_code(application.uid, device.id)
      {:ok, approved} = Oauth.decide_device_grant(grant, scope.user, :approve)
      token = CodeMySpec.Repo.get!(Oauth.AccessToken, approved.access_token_id)

      assert {:ok, [{application_id, user_id}]} =
               Oauth.revoke_device_authorization(scope, device.id)

      assert application_id == application.id
      assert user_id == scope.user.id
      refute ExOauth2Provider.AccessTokens.is_accessible?(CodeMySpec.Repo.reload!(token))

      assert {:error, :invalid_grant} =
               Oauth.poll_device_grant(grant.device_code, application.uid)

      assert {:error, %{error: "invalid_grant"}, :bad_request} =
               Oauth.grant_token(%{
                 "grant_type" => "refresh_token",
                 "client_id" => application.uid,
                 "client_secret" => application.secret,
                 "refresh_token" => token.refresh_token
               })
    end

    test "another account cannot revoke the device's authorization" do
      owner = full_scope_fixture()
      stranger = full_scope_fixture()
      device = CodeMySpec.DevicesFixtures.device_fixture(owner)
      application = oauth_application_fixture()
      {:ok, grant} = Oauth.request_device_code(application.uid, device.id)
      {:ok, approved} = Oauth.decide_device_grant(grant, owner.user, :approve)

      assert {:error, :not_found} = Oauth.revoke_device_authorization(stranger, device.id)
      token = CodeMySpec.Repo.get!(Oauth.AccessToken, approved.access_token_id)
      assert ExOauth2Provider.AccessTokens.is_accessible?(token)
    end
  end

  describe "poll_device_grant/2" do
    test "answers authorization_pending before anyone decides", %{application: application} do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())

      assert {:error, :authorization_pending} =
               Oauth.poll_device_grant(grant.device_code, application.uid)
    end

    test "the first poll after approval returns the minted token", %{
      application: application,
      user: user
    } do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())
      {:ok, decided} = Oauth.decide_device_grant(grant, user, :approve)

      assert {:ok, token} = Oauth.poll_device_grant(grant.device_code, application.uid)
      assert token.id == decided.access_token_id
    end

    test "a device_code is single-use -- a second poll after the token is returned is refused",
         %{application: application, user: user} do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())
      {:ok, _} = Oauth.decide_device_grant(grant, user, :approve)

      assert {:ok, _token} = Oauth.poll_device_grant(grant.device_code, application.uid)

      assert {:error, :invalid_grant} =
               Oauth.poll_device_grant(grant.device_code, application.uid),
             "RFC 8628 §3.5: once a device_code has been exchanged, a later poll must not " <>
               "answer the same tokens again -- anyone who later obtains the code must get nothing"
    end

    test "answers access_denied after a decline", %{application: application, user: user} do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())
      {:ok, _} = Oauth.decide_device_grant(grant, user, :deny)

      assert {:error, :access_denied} =
               Oauth.poll_device_grant(grant.device_code, application.uid)
    end

    test "answers expired_token once the code's own deadline passes", %{application: application} do
      {:ok, grant} =
        Oauth.request_device_code(application.uid, Ecto.UUID.generate(), ttl_seconds: -1)

      assert {:error, :expired_token} =
               Oauth.poll_device_grant(grant.device_code, application.uid)
    end

    test "answers invalid_grant for a code nothing issued", %{application: application} do
      assert {:error, :invalid_grant} = Oauth.poll_device_grant("no-such-code", application.uid)
    end

    test "answers invalid_grant when a different client polls someone else's code", %{
      application: application
    } do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())
      other = oauth_application_fixture()

      assert {:error, :invalid_grant} = Oauth.poll_device_grant(grant.device_code, other.uid)
    end
  end
end
