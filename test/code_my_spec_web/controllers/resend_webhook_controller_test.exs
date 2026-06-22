defmodule CodeMySpecWeb.ResendWebhookControllerTest do
  @moduledoc """
  Covers Svix signature verification on the inbound mail webhook: a correctly
  signed `email.received` event is verified and routed to a mailbox; a bad or
  missing signature is rejected with 400 once a secret is configured.
  """

  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.{Mail, Repo}

  @key :crypto.strong_rand_bytes(24)
  @secret "whsec_" <> Base.encode64(@key)
  @domain "inbound-test.example.com"

  setup do
    previous = Application.get_env(:code_my_spec, :resend_webhook_secret, "")
    Application.put_env(:code_my_spec, :resend_webhook_secret, @secret)
    on_exit(fn -> Application.put_env(:code_my_spec, :resend_webhook_secret, previous) end)

    scope = full_scope_fixture()

    project =
      scope.active_project
      |> Ecto.Changeset.change(domain: @domain)
      |> Repo.update!()

    {:ok, mailbox} = Mail.create_mailbox(scope, %{address: "support@#{@domain}"})

    %{mailbox: mailbox}
  end

  defp event_body do
    Jason.encode!(%{
      "type" => "email.received",
      "data" => %{
        "from" => "lead@example.com",
        "to" => ["support@#{@domain}"],
        "subject" => "Signed hello",
        "text" => "Did the signature check out?",
        "message_id" => "<msg-sig@example.com>"
      }
    })
  end

  defp sign(body, id \\ "msg_test", ts \\ "1700000000") do
    signed = "#{id}.#{ts}.#{body}"
    "v1," <> (:crypto.mac(:hmac, :sha256, @key, signed) |> Base.encode64())
  end

  defp post_signed(conn, body, headers) do
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")

    Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
    |> post(~p"/webhooks/resend", body)
  end

  test "a correctly signed event is verified and routed", %{conn: conn, mailbox: mailbox} do
    body = event_body()

    conn =
      post_signed(conn, body, [
        {"svix-id", "msg_test"},
        {"svix-timestamp", "1700000000"},
        {"svix-signature", sign(body)}
      ])

    assert response(conn, 200)
    assert [%{emails: [email]}] = Mail.list_threads(mailbox)
    assert email.subject == "Signed hello"
    assert email.direction == :inbound
  end

  test "a bad signature is rejected with 400 and nothing is routed", %{conn: conn, mailbox: mailbox} do
    body = event_body()

    conn =
      post_signed(conn, body, [
        {"svix-id", "msg_test"},
        {"svix-timestamp", "1700000000"},
        {"svix-signature", "v1,not-a-valid-signature"}
      ])

    assert response(conn, 400)
    assert Mail.list_threads(mailbox) == []
  end

  test "a missing signature is rejected when a secret is configured", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/resend", event_body())

    assert response(conn, 400)
  end
end
