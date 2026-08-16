defmodule CodeMySpec.MailAttachmentsTest do
  @moduledoc """
  Covers copying inbound attachments out of Resend and into our own S3 bucket.

  Both hops are stubbed with Req `plug:`s — the Resend Receiving API (list +
  the signed CDN download) under `ResendClient`, and the S3 PUT under
  `Content.S3Client` (via `ExAwsReqClient`). No network, no cassette files.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Mail
  alias CodeMySpec.Mail.{Attachments, EmailAttachment, ResendClient}
  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Repo

  @domain "att.example.com"

  setup do
    # `S3Client` is only configured here, so it stays a runtime put_env — no
    # other file in the default suite reads or writes that key. `ResendClient`
    # is pinned in `config/test.exs` and stubbed per process below, which is
    # what lets this file run beside `mail_domain_test`.
    prev_s3 = Application.get_env(:code_my_spec, S3Client, [])
    Application.put_env(:code_my_spec, S3Client, plug: {Req.Test, S3Client})
    on_exit(fn -> Application.put_env(:code_my_spec, S3Client, prev_s3) end)

    scope = full_scope_fixture()

    project =
      scope.active_project
      |> Ecto.Changeset.change(domain: @domain)
      |> Repo.update!()

    {:ok, mailbox} = Mail.create_mailbox(scope, %{address: "support@#{@domain}"})
    %{scope: scope, project: project, mailbox: mailbox}
  end

  defp stub_resend(attachments, download_status \\ 200) do
    plug = fn conn ->
      cond do
        conn.host == "api.resend.com" and String.ends_with?(conn.request_path, "/attachments") ->
          Req.Test.json(conn, %{"data" => attachments})

        conn.host == "inbound-cdn.resend.com" ->
          Plug.Conn.send_resp(conn, download_status, "FILEBYTES:" <> conn.request_path)

        true ->
          Req.Test.json(conn, %{})
      end
    end

    Req.Test.stub(ResendClient, plug)
  end

  defp stub_s3 do
    test_pid = self()

    Req.Test.stub(S3Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:s3_put, conn.request_path, body})
      Plug.Conn.send_resp(conn, 200, "")
    end)
  end

  defp att(overrides) do
    Map.merge(
      %{
        "id" => "att-1",
        "filename" => "invoice.pdf",
        "content_type" => "application/pdf",
        "content_disposition" => "attachment",
        "size" => 2048,
        "download_url" => "https://inbound-cdn.resend.com/att-1?sig=x"
      },
      overrides
    )
  end

  defp receive_with_attachment(project, domain, extra \\ %{}) do
    Mail.route_inbound(
      project,
      Map.merge(
        %{
          from: "lead@example.com",
          to: ["support@#{domain}"],
          subject: "Here is the invoice",
          text: "See attached",
          message_id: "<att-msg-1@example.com>",
          provider_email_id: "rcv-att-1",
          attachments: [%{"id" => "att-1"}]
        },
        extra
      )
    )
  end

  test "an inbound attachment is copied into S3 and recorded", ctx do
    stub_s3()
    stub_resend([att(%{})])

    {:ok, email} = receive_with_attachment(ctx.project, @domain)

    assert [stored] = Repo.all(EmailAttachment)
    assert stored.email_id == email.id
    assert stored.filename == "invoice.pdf"
    assert stored.content_type == "application/pdf"
    assert stored.content_disposition == "attachment"
    assert stored.size == 2048
    assert stored.provider_attachment_id == "att-1"
    assert stored.s3_key == "mail/#{ctx.mailbox.id}/#{email.id}/att-1/invoice.pdf"

    assert_receive {:s3_put, path, body}
    assert path =~ "invoice.pdf"
    assert body == "FILEBYTES:/att-1"
  end

  test "storing is idempotent by provider attachment id", ctx do
    stub_s3()
    stub_resend([att(%{})])

    {:ok, email} = receive_with_attachment(ctx.project, @domain)
    assert length(Repo.all(EmailAttachment)) == 1

    # A re-delivered webhook / sync pass must not duplicate the file.
    Attachments.store_inbound(email)
    assert length(Repo.all(EmailAttachment)) == 1
  end

  test "a filename with unsafe characters is sanitized in the S3 key", ctx do
    stub_s3()
    stub_resend([att(%{"filename" => "../../secret file (v2).pdf"})])

    {:ok, email} = receive_with_attachment(ctx.project, @domain)

    assert [stored] = Repo.all(EmailAttachment)
    assert stored.s3_key == "mail/#{ctx.mailbox.id}/#{email.id}/att-1/secret_file_v2_.pdf"
  end

  test "a download failure is best-effort: the email survives, no attachment row", ctx do
    stub_s3()
    stub_resend([att(%{})], 500)

    {:ok, email} = receive_with_attachment(ctx.project, @domain)

    assert Repo.all(EmailAttachment) == []
    assert Repo.get!(CodeMySpec.Mail.Email, email.id).subject == "Here is the invoice"
  end

  test "no attachments metadata means the provider is never called", ctx do
    # No stub installed. A Resend call would now raise and name the client
    # rather than returning a soft `:resend_not_configured` the gated path
    # could swallow — the assertion is that it is never reached.

    {:ok, _email} =
      Mail.route_inbound(ctx.project, %{
        from: "lead@example.com",
        to: ["support@#{@domain}"],
        subject: "No files here",
        text: "hi",
        message_id: "<plain@example.com>",
        provider_email_id: "rcv-plain"
      })

    assert Repo.all(EmailAttachment) == []
  end

  test "get_attachment is scoped to visible mailboxes and yields a download URL", ctx do
    stub_s3()
    stub_resend([att(%{})])

    {:ok, _email} = receive_with_attachment(ctx.project, @domain)
    [stored] = Repo.all(EmailAttachment)

    assert %EmailAttachment{} = found = Mail.get_attachment(ctx.scope, stored.id)
    assert found.id == stored.id
    assert {:ok, url} = Mail.attachment_download_url(found)
    assert url =~ stored.s3_key |> URI.encode() |> String.replace("/", "%2F") or url =~ "invoice.pdf"

    # A scope on another project can't see it.
    other = full_scope_fixture()
    assert Mail.get_attachment(other, stored.id) == nil
  end
end
