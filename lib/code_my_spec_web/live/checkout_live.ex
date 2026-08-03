defmodule CodeMySpecWeb.CheckoutLive do
  @moduledoc """
  Buying a tier, embedded in the pricing page.

  Nested inside the marketing page with `live_render` rather than replacing it:
  that page is a dead view with canonical and og tags and no socket, and it
  should stay that way — a websocket on every marketing pageview is a real cost
  for a form only buyers use.

  Nothing here grants a plan. Confirming the payment tells Stripe, Stripe tells
  the webhook, and the webhook writes the tier. The page only reflects it.
  """

  use CodeMySpecWeb, :live_view

  # Nested in a dead view, so the router's live_session on_mount hooks never
  # run and nothing has assigned current_scope. The session token is still
  # there, so scope is derived here rather than assumed.
  on_mount {CodeMySpecWeb.UserAuth, :mount_current_scope}

  alias CodeMySpec.Billing
  alias CodeMySpec.Users.Scope

  @tiers [
    %{
      id: :light,
      name: "Light harness",
      price: "$25",
      blurb: "The harness on your machine. You bring the compute, we bring the method."
    },
    %{
      id: :pro,
      name: "Our agent, our infra",
      price: "$100",
      blurb: "We run the agent and the box. You describe the work."
    }
  ]

  def render(assigns) do
    ~H"""
    <div id="checkout" class="mt-10">
      <.signed_out :if={!@current_scope || !@current_scope.user} />

      <%= if @current_scope && @current_scope.user do %>
        <.paying :if={@client_secret} client_secret={@client_secret} tier={@tier} pk={@publishable_key} />
        <.tier_choice :if={!@client_secret} tiers={@tiers} current_plan={@current_plan} />
        <p :if={@error} class="text-error text-sm mt-3">{@error}</p>
      <% end %>
    </div>
    """
  end

  defp signed_out(assigns) do
    ~H"""
    <p class="text-base-content/70">
      <.link navigate={~p"/users/log-in"} class="link link-primary">Sign in</.link>
      to pick a plan — a plan belongs to an account, so we need to know whose.
    </p>
    """
  end

  defp tier_choice(assigns) do
    ~H"""
    <div class="grid gap-4 md:grid-cols-2">
      <div :for={tier <- @tiers} class="card bg-base-200">
        <div class="card-body">
          <h3 class="card-title">{tier.name}</h3>
          <p class="text-2xl font-bold">{tier.price}<span class="text-sm font-normal">/month</span></p>
          <p class="text-base-content/70">{tier.blurb}</p>

          <div class="card-actions justify-end mt-2">
            <span :if={@current_plan == tier.id} class="badge badge-primary">Your plan</span>
            <.button
              :if={@current_plan != tier.id}
              phx-click="choose"
              phx-value-tier={tier.id}
              class="btn-primary"
            >
              Choose {tier.name}
            </.button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp paying(assigns) do
    ~H"""
    <div
      id="stripe-payment"
      phx-hook="StripePaymentElement"
      phx-update="ignore"
      data-publishable-key={@pk}
      data-client-secret={@client_secret}
    >
      <p class="mb-3 text-base-content/70">Paying for the {@tier} plan.</p>
      <form id="payment-form">
        <div id="payment-element"></div>
        <button id="payment-submit" class="btn btn-primary mt-4" type="submit">Pay</button>
        <p id="payment-error" class="text-error text-sm mt-2"></p>
      </form>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(tiers: @tiers, client_secret: nil, tier: nil, error: nil)
     |> assign(publishable_key: publishable_key())
     |> assign_current_plan()}
  end

  def handle_event("choose", %{"tier" => tier}, socket) do
    tier = String.to_existing_atom(tier)

    case Billing.start_subscription(socket.assigns.current_scope, tier) do
      {:ok, %{client_secret: secret}} ->
        {:noreply, assign(socket, client_secret: secret, tier: tier, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: message_for(reason))}
    end
  end

  # The browser confirmed the payment. Stripe has it; the webhook has the last
  # word on the tier, so this only tells the user where things stand.
  def handle_event("payment_confirmed", _params, socket) do
    {:noreply,
     socket
     |> assign(client_secret: nil, error: nil)
     |> put_flash(:info, "Payment received. Your plan will be active in a moment.")}
  end

  def handle_event("payment_failed", %{"message" => message}, socket) do
    {:noreply, assign(socket, error: message)}
  end

  defp assign_current_plan(socket) do
    assign(socket, :current_plan, current_plan(socket.assigns[:current_scope]))
  end

  defp current_plan(%Scope{active_account: %{plan: plan}}), do: plan
  defp current_plan(_scope), do: nil

  defp message_for(:stripe_not_configured), do: "Payments aren't set up yet."
  defp message_for(:no_client_secret), do: "Stripe didn't give us a way to take the payment."

  defp message_for(%{body: %{"error" => %{"message" => message}}}) when is_binary(message),
    do: message

  defp message_for(_reason), do: "That didn't go through. Try again."

  defp publishable_key do
    Application.get_env(:code_my_spec, CodeMySpec.Billing, [])[:publishable_key] || ""
  end
end
