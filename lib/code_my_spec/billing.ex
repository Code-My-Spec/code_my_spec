defmodule CodeMySpec.Billing do
  @moduledoc """
  Buying a plan, and the plan an account is on.

  The shape of this context is one decision: **the webhook is the only writer
  of `account.plan`.** Starting a subscription hands the browser a client
  secret and writes nothing about entitlement; the tier flips later, when
  Stripe tells us the money actually moved. A page that granted the plan on
  its own would mean a closed tab is a free upgrade, and it would have no
  answer at all for renewals, failures or cancellations — all of which arrive
  as webhooks and never as page loads.

  Lifecycle, as decided:

    * Cancelling keeps the tier until the period already paid for ends.
    * A failed renewal keeps the tier while Stripe retries; only Stripe giving
      up returns the account to free.
  """

  import Ecto.Query

  alias CodeMySpec.Accounts
  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Billing.{StripeClient, StripeEvent}
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  require Logger

  @tiers [:light, :pro]

  @doc "The tiers a user can buy. `:free` is not bought and `:paid` is legacy."
  @spec tiers() :: [atom()]
  def tiers, do: @tiers

  @doc """
  Starts a subscription for `tier` and returns the secret the browser confirms.

  Nothing about the account's plan changes here — see the moduledoc.
  """
  @spec start_subscription(Scope.t(), atom()) ::
          {:ok, %{client_secret: String.t(), subscription_id: String.t()}} | {:error, term()}
  def start_subscription(%Scope{} = scope, tier) when tier in @tiers do
    with {:ok, account} <- ensure_customer(scope),
         {:ok, subscription} <-
           StripeClient.create_subscription(%{
             "customer" => account.stripe_customer_id,
             "items[0][price]" => price_id!(tier),
             "items[0][quantity]" => "1",
             # Leaves the subscription unpaid until the browser confirms, which
             # is what makes this embedded rather than a redirect.
             "payment_behavior" => "default_incomplete",
             "payment_settings[save_default_payment_method]" => "on_subscription",
             "metadata[account_id]" => account.id,
             "metadata[tier]" => to_string(tier),
             "expand[0]" => "latest_invoice.confirmation_secret"
           }) do
      client_secret(subscription)
    end
  end

  defp client_secret(subscription) do
    case get_in(subscription, ["latest_invoice", "confirmation_secret", "client_secret"]) do
      secret when is_binary(secret) ->
        {:ok, %{client_secret: secret, subscription_id: subscription["id"]}}

      _ ->
        # Without the expand there is no secret and the Payment Element has
        # nothing to confirm — a silent misconfiguration rather than a decline.
        {:error, :no_client_secret}
    end
  end

  @doc "The account's Stripe customer, created on first use and reused after."
  @spec ensure_customer(Scope.t()) :: {:ok, Account.t()} | {:error, term()}
  def ensure_customer(%Scope{active_account: %Account{stripe_customer_id: id} = account})
      when is_binary(id),
      do: {:ok, account}

  def ensure_customer(%Scope{active_account: %Account{} = account} = scope) do
    with {:ok, customer} <-
           StripeClient.create_customer(%{
             "email" => scope.user.email,
             "name" => account.name,
             "metadata[account_id]" => account.id
           }) do
      Accounts.update_account(scope, account, %{stripe_customer_id: customer["id"]})
    end
  end

  @doc """
  Applies a Stripe event, once.

  The dedup row goes in first: if the insert conflicts the event has already
  been applied and this is a redelivery, which Stripe does routinely.
  """
  @spec apply_event(map()) :: :ok | {:error, term()}
  def apply_event(%{"id" => event_id, "type" => type} = event) do
    case record_event(event_id, type) do
      {:ok, _} -> handle(type, event)
      {:error, changeset} -> already_applied(changeset, event_id)
    end
  end

  defp already_applied(%Ecto.Changeset{} = changeset, event_id) do
    case duplicate_event?(changeset) do
      true ->
        Logger.info("[Billing] ignoring redelivered Stripe event #{event_id}")
        :ok

      false ->
        {:error, changeset}
    end
  end

  defp duplicate_event?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:event_id, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp record_event(event_id, type) do
    %StripeEvent{} |> StripeEvent.changeset(%{event_id: event_id, type: type}) |> Repo.insert()
  end

  # Money moved. This is the only place a paid tier is granted.
  defp handle("invoice.payment_succeeded", event) do
    with {:ok, account} <- account_for(event) do
      set_plan(account, tier_for(event) || account.plan)
    end
  end

  # Stripe has stopped trying — either a cancellation whose period ended, or a
  # renewal it gave up on. Both mean the account is no longer paid for.
  defp handle("customer.subscription.deleted", event) do
    with {:ok, account} <- account_for(event) do
      set_plan(account, :free)
    end
  end

  # A failed renewal is not a cancellation. Stripe retries for days, and most
  # of these are an expired card that gets fixed — so the tier stays and the
  # user is told, rather than being cut off over something recoverable.
  defp handle("invoice.payment_failed", event) do
    with {:ok, account} <- account_for(event) do
      Logger.warning("[Billing] renewal failed for account #{account.id}; tier retained")
      :ok
    end
  end

  defp handle(type, _event) do
    Logger.debug("[Billing] ignoring unhandled Stripe event #{type}")
    :ok
  end

  defp set_plan(%Account{} = account, plan) do
    account
    |> Ecto.Changeset.change(plan: plan)
    |> Repo.update()
    |> case do
      {:ok, _account} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The account id is stamped into metadata at subscription time precisely so
  # a webhook can be reconciled without trusting anything the browser sent.
  defp account_for(event) do
    case account_id(event) do
      nil ->
        {:error, :no_account_reference}

      id ->
        case Repo.one(from a in Account, where: a.id == ^id) do
          %Account{} = account -> {:ok, account}
          nil -> {:error, :unknown_account}
        end
    end
  end

  defp account_id(event) do
    get_in(event, ["data", "object", "metadata", "account_id"]) ||
      get_in(event, ["data", "object", "subscription_details", "metadata", "account_id"])
  end

  defp tier_for(event) do
    case get_in(event, ["data", "object", "metadata", "tier"]) ||
           get_in(event, ["data", "object", "subscription_details", "metadata", "tier"]) do
      "light" -> :light
      "pro" -> :pro
      _ -> nil
    end
  end

  defp price_id!(tier) do
    config = Application.get_env(:code_my_spec, __MODULE__, [])

    case config[:"#{tier}_price_id"] do
      id when is_binary(id) and id != "" -> id
      _ -> raise "no Stripe price id configured for the #{tier} tier"
    end
  end
end
