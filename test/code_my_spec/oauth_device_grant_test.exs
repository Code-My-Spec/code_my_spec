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
      assert {:error, :invalid_client} = Oauth.request_device_code("no-such-client", Ecto.UUID.generate())
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

      assert %{id: id} = Oauth.get_device_grant_by_user_code(" #{String.downcase(grant.user_code)} ")
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
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate(), ttl_seconds: -1)

      assert {:error, :expired} = Oauth.decide_device_grant(grant, user, :approve)
    end
  end

  describe "poll_device_grant/2" do
    test "answers authorization_pending before anyone decides", %{application: application} do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())

      assert {:error, :authorization_pending} =
               Oauth.poll_device_grant(grant.device_code, application.uid)
    end

    test "answers the same minted token on every poll after approval", %{
      application: application,
      user: user
    } do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())
      {:ok, _} = Oauth.decide_device_grant(grant, user, :approve)

      assert {:ok, first} = Oauth.poll_device_grant(grant.device_code, application.uid)
      assert {:ok, second} = Oauth.poll_device_grant(grant.device_code, application.uid)

      assert first.id == second.id,
             "a second poll after approval minted a different token instead of reusing it"
    end

    test "answers access_denied after a decline", %{application: application, user: user} do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate())
      {:ok, _} = Oauth.decide_device_grant(grant, user, :deny)

      assert {:error, :access_denied} = Oauth.poll_device_grant(grant.device_code, application.uid)
    end

    test "answers expired_token once the code's own deadline passes", %{application: application} do
      {:ok, grant} = Oauth.request_device_code(application.uid, Ecto.UUID.generate(), ttl_seconds: -1)

      assert {:error, :expired_token} = Oauth.poll_device_grant(grant.device_code, application.uid)
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
