defmodule CodeMySpecWeb.ResendWebhookController do
  @moduledoc """
  Inbound mail webhook for the Resend Receiving API.

  Resend POSTs an `email.received` event here; we resolve the owning project
  by the To-address domain and route the message into a mailbox (catch-all
  fallback) via `CodeMySpec.Mail.route_inbound/2`. We always answer 200 so the
  provider doesn't retry on messages we have nowhere to put.

  Signature verification is deferred for v1 (see
  `priv/knowledge/resend/receiving.md`); the endpoint is unauthenticated.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Mail

  def inbound(conn, %{"type" => "email.received", "data" => data}) when is_map(data) do
    to = data |> Map.get("to") |> List.wrap() |> List.first()

    with domain when is_binary(domain) <- address_domain(to),
         project when not is_nil(project) <- Mail.get_project_by_domain(domain) do
      Mail.route_inbound(project, %{
        from: Map.get(data, "from"),
        to: Map.get(data, "to"),
        subject: Map.get(data, "subject"),
        text: Map.get(data, "text"),
        html: Map.get(data, "html"),
        message_id: Map.get(data, "message_id"),
        in_reply_to: Map.get(data, "in_reply_to")
      })
    end

    send_resp(conn, 200, "ok")
  end

  def inbound(conn, _params), do: send_resp(conn, 200, "ok")

  defp address_domain(address) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [_local, domain] when domain != "" -> domain
      _ -> nil
    end
  end

  defp address_domain(_), do: nil
end
