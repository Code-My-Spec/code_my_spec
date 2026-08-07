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
      set_plan(account, tier_for(event) || account.plan, subscription_id(event))
    end
  end

  # Stripe has stopped trying — either a cancellation whose period ended, or a
  # renewal it gave up on. Both mean the account is no longer paid for.
  defp handle("customer.subscription.deleted", event) do
    with {:ok, account} <- account_for(event) do
      set_plan(account, :free, nil)
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

  defp set_plan(%Account{} = account, plan, subscription_id) do
    account
    |> Ecto.Changeset.change(plan: plan)
    |> put_subscription_id(subscription_id)
    |> Repo.update()
    |> case do
      {:ok, _account} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Only ever recorded, never cleared: knowing which subscription paid for a
  # tier is what makes a cancellation or a refund traceable afterwards.
  defp put_subscription_id(changeset, nil), do: changeset

  defp put_subscription_id(changeset, id),
    do: Ecto.Changeset.change(changeset, stripe_subscription_id: id)

  # Same shape problem as the metadata: an invoice references its subscription
  # under `parent.subscription_details`, while a subscription event is the
  # subscription. Both have to resolve or the id silently stays null.
  defp subscription_id(event) do
    object = get_in(event, ["data", "object"]) || %{}

    case object["object"] do
      "subscription" ->
        object["id"]

      _ ->
        get_in(object, ["parent", "subscription_details", "subscription"]) ||
          get_in(object, ["subscription_details", "subscription"]) ||
          object["subscription"]
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

  defp account_id(event), do: metadata(event)["account_id"]

  # Where the metadata actually is depends on the object. A subscription event
  # carries it at the top; an invoice does not carry it at all — it mirrors the
  # subscription's under `parent.subscription_details`. Guessing at that path
  # cost a real payment: the event arrived, was deduped, and granted nothing,
  # because the id it needed was two levels deeper than the tests pretended.
  defp metadata(event) do
    object = get_in(event, ["data", "object"]) || %{}

    non_empty(object["metadata"]) ||
      non_empty(get_in(object, ["parent", "subscription_details", "metadata"])) ||
      non_empty(get_in(object, ["subscription_details", "metadata"])) ||
      %{}
  end

  defp non_empty(map) when is_map(map) and map_size(map) > 0, do: map
  defp non_empty(_), do: nil

  defp tier_for(event) do
    case metadata(event)["tier"] do
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
