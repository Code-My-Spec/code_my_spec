defmodule CodeMySpec.MailDomainTest do
  @moduledoc """
  Covers the Resend-backed domain onboarding flow in `CodeMySpec.Mail`:
  register a sending domain, read its DNS records/status, and verify it.

  HTTP is stubbed with a Req `plug:` (no network, no cassette files) and a
  fake api_key is installed under the client's config key for the duration of
  each test so the client actually issues requests rather than short-circuiting
  on a missing key.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Mail
  alias CodeMySpec.Mail.ResendClient
  alias CodeMySpec.Projects

  @records [
    %{"type" => "TXT", "name" => "resend._domainkey", "value" => "p=ABC", "status" => "pending"},
    %{"type" => "TXT", "name" => "@", "value" => "v=spf1 include:resend", "status" => "pending"}
  ]

  setup do
    previous = Application.get_env(:code_my_spec, ResendClient, [])
    on_exit(fn -> Application.put_env(:code_my_spec, ResendClient, previous) end)
    :ok
  end

  defp install_plug(status) do
    plug = fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/domains"} ->
          Req.Test.json(conn, %{"id" => "dom_1", "name" => "x", "status" => "not_started", "records" => @records})

        {"POST", "/domains/dom_1/verify"} ->
          Req.Test.json(conn, %{"id" => "dom_1", "status" => status})

        {"GET", "/domains/dom_1"} ->
          Req.Test.json(conn, %{"id" => "dom_1", "status" => status, "records" => @records})
      end
    end

    Application.put_env(:code_my_spec, ResendClient, api_key: "re_test_key", plug: plug)
  end

  describe "setup_domain/3" do
    test "registers the domain and persists name + resend id" do
      install_plug("not_started")
      scope = full_scope_fixture()

      assert {:ok, project, records} =
               Mail.setup_domain(scope, scope.active_project, "inbound.sam-ships.com")

      assert project.domain == "inbound.sam-ships.com"
      assert project.resend_domain_id == "dom_1"
      refute project.domain_verified_at
      assert records == @records

      # Persisted, not just returned.
      {:ok, reloaded} = Projects.get_project(scope, project.id)
      assert reloaded.resend_domain_id == "dom_1"
    end

    test "surfaces a clear error when the provider key is missing" do
      Application.put_env(:code_my_spec, ResendClient, api_key: "", plug: nil)
      scope = full_scope_fixture()

      assert {:error, :resend_not_configured} =
               Mail.setup_domain(scope, scope.active_project, "inbound.sam-ships.com")
    end
  end

  describe "verify_domain/2" do
    test "stamps domain_verified_at once Resend reports verified" do
      install_plug("verified")
      scope = full_scope_fixture()

      {:ok, project, _records} =
        Mail.setup_domain(scope, scope.active_project, "inbound.sam-ships.com")

      assert {:ok, verified, :verified} = Mail.verify_domain(scope, project)
      assert %DateTime{} = verified.domain_verified_at

      {:ok, reloaded} = Projects.get_project(scope, project.id)
      assert reloaded.domain_verified_at
    end

    test "leaves the domain unverified while DNS is still pending" do
      install_plug("pending")
      scope = full_scope_fixture()

      {:ok, project, _records} =
        Mail.setup_domain(scope, scope.active_project, "inbound.sam-ships.com")

      assert {:ok, still_pending, "pending"} = Mail.verify_domain(scope, project)
      refute still_pending.domain_verified_at
    end

    test "returns :no_domain when the project has no registered domain" do
      scope = full_scope_fixture()
      assert {:error, :no_domain} = Mail.verify_domain(scope, scope.active_project)
    end
  end

  describe "domain_dns_records/1" do
    test "reads the current records and status from the provider" do
      install_plug("pending")
      scope = full_scope_fixture()

      {:ok, project, _records} =
        Mail.setup_domain(scope, scope.active_project, "inbound.sam-ships.com")

      assert {:ok, records, "pending"} = Mail.domain_dns_records(project)
      assert records == @records
    end
  end
end
