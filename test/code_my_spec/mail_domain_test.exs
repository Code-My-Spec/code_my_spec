defmodule CodeMySpec.MailDomainTest do
  @moduledoc """
  Covers the Resend-backed domain onboarding flow in `CodeMySpec.Mail`:
  register a sending domain, read its DNS records/status, and verify it.

  HTTP is stubbed through `Req.Test`, which resolves a stub against the
  calling process — so this file and `mail_attachments_test` can drive the
  same client at once. The api_key and the `{Req.Test, ResendClient}` plug are
  pinned in `config/test.exs`; only the response varies per test.

  A test that installs no stub is asserting the provider is never reached: any
  call raises and names the client, rather than returning a soft
  `:resend_not_configured` that a gated path could swallow.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Mail
  alias CodeMySpec.Mail.ResendClient
  alias CodeMySpec.Projects
  alias Req.Test

  @records [
    %{"type" => "TXT", "name" => "resend._domainkey", "value" => "p=ABC", "status" => "pending"},
    %{"type" => "TXT", "name" => "@", "value" => "v=spf1 include:resend", "status" => "pending"}
  ]

  defp install_plug(status) do
    Test.stub(ResendClient, &domain_response(&1, status))
  end

  defp domain_response(%{method: "POST", request_path: "/domains"} = conn, _status) do
    Test.json(conn, %{
      "id" => "dom_1",
      "name" => "x",
      "status" => "not_started",
      "records" => @records
    })
  end

  defp domain_response(%{method: "POST", request_path: "/domains/dom_1/verify"} = conn, status) do
    Test.json(conn, %{"id" => "dom_1", "status" => status})
  end

  defp domain_response(%{method: "GET", request_path: "/domains/dom_1"} = conn, status) do
    Test.json(conn, %{"id" => "dom_1", "status" => status, "records" => @records})
  end

  defp adopt_existing_domain_response(%{method: "POST", request_path: "/domains"} = conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      403,
      Jason.encode!(%{"name" => "validation_error", "message" => "domain already exists"})
    )
  end

  defp adopt_existing_domain_response(%{method: "GET", request_path: "/domains"} = conn) do
    Test.json(conn, %{
      "object" => "list",
      "data" => [
        %{"id" => "dom_existing", "name" => "inbound.sam-ships.com", "status" => "verified"}
      ]
    })
  end

  defp adopt_existing_domain_response(
         %{method: "GET", request_path: "/domains/dom_existing"} = conn
       ) do
    Test.json(conn, %{"id" => "dom_existing", "status" => "verified", "records" => @records})
  end

  defp send_email_response(%{method: "POST", request_path: "/emails"} = conn) do
    Test.json(conn, %{"id" => "email_1"})
  end

  defp fetch_body_response(%{method: "GET", request_path: "/emails/receiving/" <> _} = conn) do
    Test.json(conn, %{"text" => "Fetched body", "html" => "<p>Fetched body</p>"})
  end

  defp install_route(conn, "POST", "/domains", _status) do
    Test.json(conn, %{
      "id" => "dom_1",
      "name" => "x",
      "status" => "not_started",
      "records" => @records
    })
  end

  defp install_route(conn, "POST", "/domains/dom_1/verify", status) do
    Test.json(conn, %{"id" => "dom_1", "status" => status})
  end

  defp install_route(conn, "GET", "/domains/dom_1", status) do
    Test.json(conn, %{"id" => "dom_1", "status" => status, "records" => @records})
  end

  defp respond_email_sent(%{method: "POST", request_path: "/emails"} = conn),
    do: Test.json(conn, %{"id" => "email_1"})

  defp respond_fetched_body(%{method: "GET", request_path: "/emails/receiving/" <> _} = conn) do
    Test.json(conn, %{"text" => "Fetched body", "html" => "<p>Fetched body</p>"})
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

    test "adopts an already-registered domain when the provider rejects creation" do
      Test.stub(ResendClient, &adopt_existing_domain_response/1)
      scope = full_scope_fixture()

      assert {:ok, project, records} =
               Mail.setup_domain(scope, scope.active_project, "inbound.sam-ships.com")

      assert project.resend_domain_id == "dom_existing"
      # Adopted domain was already verified — mail should unlock immediately.
      assert %DateTime{} = project.domain_verified_at
      assert records == @records
    end
  end

  defp adopt_route(%{method: "POST", request_path: "/domains"} = conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      403,
      Jason.encode!(%{"name" => "validation_error", "message" => "domain already exists"})
    )
  end

  defp adopt_route(%{method: "GET", request_path: "/domains"} = conn) do
    Test.json(conn, %{
      "object" => "list",
      "data" => [
        %{
          "id" => "dom_existing",
          "name" => "inbound.sam-ships.com",
          "status" => "verified"
        }
      ]
    })
  end

  defp adopt_route(%{method: "GET", request_path: "/domains/dom_existing"} = conn) do
    Test.json(conn, %{
      "id" => "dom_existing",
      "status" => "verified",
      "records" => @records
    })
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

  describe "send_outbound/2 (Resend delivery)" do
    test "sends via the provider and records the returned provider id" do
      Test.stub(ResendClient, &send_email_response/1)
      scope = full_scope_fixture()
      {:ok, mailbox} = Mail.create_mailbox(scope, %{address: "support@sam-ships.com"})

      assert {:ok, email} =
               Mail.send_outbound(mailbox, %{to: "lead@example.com", subject: "Hi", body: "Hello"})

      assert email.direction == :outbound
      assert email.from_address == "support@sam-ships.com"
      assert email.provider_id == "email_1"
    end

    test "persists the email even when the provider send fails" do
      # A provider that answers badly, rather than a client that was never
      # configured. What this replaced blanked the api_key, so the send never
      # left the process and the test proved the *unconfigured* path rather
      # than the failing-provider one it is named for — the two reach the same
      # `{:error, _}` in `deliver/3` from opposite directions.
      Test.stub(ResendClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"message":"upstream unavailable"}))
      end)

      scope = full_scope_fixture()
      {:ok, mailbox} = Mail.create_mailbox(scope, %{address: "support@sam-ships.com"})

      assert {:ok, email} =
               Mail.send_outbound(mailbox, %{to: "lead@example.com", subject: "Hi", body: "Hello"})

      assert email.from_address == "support@sam-ships.com"
      refute email.provider_id
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

  describe "list_threads/1 (address + subject threading)" do
    setup do
      scope = full_scope_fixture()

      project =
        scope.active_project
        |> Ecto.Changeset.change(domain: "threads.example.com")
        |> CodeMySpec.Repo.update!()

      {:ok, mailbox} = Mail.create_mailbox(scope, %{address: "support@threads.example.com"})
      %{project: project, mailbox: mailbox}
    end

    defp inbound(project, from, subject) do
      {:ok, _} =
        Mail.route_inbound(project, %{
          from: from,
          to: ["support@threads.example.com"],
          subject: subject,
          text: subject
        })
    end

    test "different subjects from the same correspondent are separate threads", ctx do
      inbound(ctx.project, "a@x.com", "Invoice question")
      inbound(ctx.project, "a@x.com", "Refund request")

      threads = Mail.list_threads(ctx.mailbox)
      assert length(threads) == 2
      assert Enum.map(threads, & &1.correspondent) |> Enum.uniq() == ["a@x.com"]
    end

    test "a Re: reply threads with the original subject", ctx do
      inbound(ctx.project, "a@x.com", "Pricing")
      inbound(ctx.project, "a@x.com", "Re: Pricing")

      assert [thread] = Mail.list_threads(ctx.mailbox)
      assert length(thread.emails) == 2
      assert thread.subject == "Pricing"
    end

    test "same subject from different correspondents are separate threads", ctx do
      inbound(ctx.project, "a@x.com", "Hello")
      inbound(ctx.project, "b@y.com", "Hello")

      assert length(Mail.list_threads(ctx.mailbox)) == 2
    end
  end

  describe "route_inbound/2 fetches the body (metadata-only webhook)" do
    setup do
      scope = full_scope_fixture()

      project =
        scope.active_project
        |> Ecto.Changeset.change(domain: "fetch.example.com")
        |> CodeMySpec.Repo.update!()

      {:ok, _mailbox} = Mail.create_mailbox(scope, %{address: "support@fetch.example.com"})
      %{project: project}
    end

    test "pulls text/html from the Receiving API when the event carries none", ctx do
      Test.stub(ResendClient, &fetch_body_response/1)

      {:ok, email} =
        Mail.route_inbound(ctx.project, %{
          from: "lead@example.com",
          to: ["support@fetch.example.com"],
          subject: "No body in the event",
          provider_email_id: "rcv_123"
        })

      assert email.body_text == "Fetched body"
      assert email.body_html == "<p>Fetched body</p>"
      assert email.provider_id == "rcv_123"
    end

    test "uses the event body when present (no fetch)", ctx do
      # No stub: the event body is used, so nothing should be fetched.
      {:ok, email} =
        Mail.route_inbound(ctx.project, %{
          from: "lead@example.com",
          to: ["support@fetch.example.com"],
          subject: "Inline",
          text: "Inline body",
          provider_email_id: "rcv_x"
        })

      assert email.body_text == "Inline body"
    end
  end

  describe "sync_inbound/2 (reconcile from Receiving API)" do
    setup do
      scope = full_scope_fixture()

      project =
        scope.active_project
        |> Ecto.Changeset.change(domain: "sync.example.com")
        |> CodeMySpec.Repo.update!()

      {:ok, mailbox} = Mail.create_mailbox(scope, %{address: "support@sync.example.com"})
      %{project: project, mailbox: mailbox}
    end

    defp sync_plug do
      received = %{
        "data" => [
          %{
            "id" => "rcv1",
            "to" => ["support@sync.example.com"],
            "from" => "a@x.com",
            "subject" => "Missed",
            "message_id" => "<m1@x>"
          }
        ]
      }

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, sync_body(conn, received))
      end

      Test.stub(ResendClient, plug)
    end

    defp sync_body(%{method: "GET", request_path: "/emails/receiving/" <> _}, _received),
      do: Jason.encode!(%{"text" => "Recovered body", "html" => "<p>Recovered body</p>"})

    defp sync_body(%{method: "GET", request_path: "/emails/receiving"}, received),
      do: Jason.encode!(received)

    test "inserts inbound the project never recorded and reports counts", ctx do
      sync_plug()

      assert {:ok, %{synced: 1, new: 1, backfilled: 0}} = Mail.sync_inbound(ctx.project)
      assert [%{emails: [email]}] = Mail.list_threads(ctx.mailbox)
      assert email.body_text == "Recovered body"
      assert email.message_id == "<m1@x>"
    end

    test "backfills the body of a metadata-only row", ctx do
      {:ok, blank} =
        Mail.route_inbound(ctx.project, %{
          from: "a@x.com",
          to: ["support@sync.example.com"],
          subject: "Missed",
          message_id: "<m1@x>"
        })

      refute blank.body_text

      sync_plug()

      assert {:ok, %{new: 0, backfilled: 1}} = Mail.sync_inbound(ctx.project)
      assert [%{emails: [email]}] = Mail.list_threads(ctx.mailbox)
      assert email.body_text == "Recovered body"
    end

    test "skips messages already fully recorded", ctx do
      {:ok, _} =
        Mail.route_inbound(ctx.project, %{
          from: "a@x.com",
          to: ["support@sync.example.com"],
          subject: "Missed",
          text: "already here",
          message_id: "<m1@x>"
        })

      sync_plug()

      assert {:ok, %{new: 0, backfilled: 0}} = Mail.sync_inbound(ctx.project)
    end
  end
end
