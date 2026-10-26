defmodule CodeMySpecSpex.Story993.Criterion800Spex do
  @moduledoc """
  Story 993 — Buying a plan puts the account on it.
  Criterion 800 — Abandoning checkout costs the user nothing.

  Choosing a tier prepares an incomplete Stripe subscription. Until the buyer
  confirms its payment, closing checkout must leave the account free.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Billing.StripeClient,
      secret_key: "sk_test_abandoned",
      plug: {Req.Test, CodeMySpec.Billing.StripeClient}
    )

    Application.put_env(:code_my_spec, CodeMySpec.Billing,
      light_price_id: "price_light_abandoned",
      pro_price_id: "price_pro_abandoned",
      publishable_key: "pk_test_abandoned"
    )

    on_exit(fn ->
      Application.delete_env(:code_my_spec, CodeMySpec.Billing.StripeClient)
      Application.delete_env(:code_my_spec, CodeMySpec.Billing)
    end)

    :ok
  end

  spex "Leaving checkout before payment leaves the account free", criterion: 800 do
    scenario "the buyer chooses a tier and closes checkout without paying" do
      given_ "a signed-in free account looking at pricing", context do
        {:ok, requests} = Agent.start_link(fn -> [] end)
        Req.Test.stub(CodeMySpec.Billing.StripeClient, &stripe_response(&1, requests))
        {:ok, checkout, _html} = live_isolated(context.conn, CodeMySpecWeb.CheckoutLive)
        {:ok, Map.merge(context, %{checkout: checkout, requests: requests})}
      end

      when_ "the buyer chooses light harness and leaves before confirming payment", context do
        context.checkout
        |> element("button[phx-value-tier='light']")
        |> render_click()

        payment_html = render(context.checkout)
        GenServer.stop(context.checkout.pid)
        {:ok, Map.put(context, :payment_html, payment_html)}
      end

      then_ "Stripe has only an incomplete subscription and the account is still free", context do
        assert context.payment_html =~ ~s(id="payment-element")
        assert context.payment_html =~ ~s(data-client-secret="pi_abandoned_secret")

        requests = Agent.get(context.requests, &Enum.reverse/1)
        assert ["/v1/customers", "/v1/subscriptions"] == Enum.map(requests, &elem(&1, 0))
        {"/v1/subscriptions", form} = List.last(requests)
        assert form =~ "payment_behavior=default_incomplete"
        assert plan_on_page(context.conn) == nil
        {:ok, context}
      end
    end
  end

  defp stripe_response(%{request_path: "/v1/customers"} = conn, requests) do
    record_and_respond(conn, requests, %{"id" => "cus_abandoned"})
  end

  defp stripe_response(%{request_path: "/v1/subscriptions"} = conn, requests) do
    record_and_respond(conn, requests, %{
      "id" => "sub_abandoned",
      "latest_invoice" => %{
        "confirmation_secret" => %{"client_secret" => "pi_abandoned_secret"}
      }
    })
  end

  defp record_and_respond(%{request_path: path} = conn, requests, response) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    Agent.update(requests, &[{path, body} | &1])

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(response))
  end
end
