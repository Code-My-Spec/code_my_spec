defmodule CodeMySpec.Billing do
  @moduledoc """
  Buying a plan, and the plan an account is on.

  **The webhook is the only writer of `account.plan`.** Starting a
  subscription hands the browser a client secret and writes nothing about
  entitlement; the tier flips when Stripe reports the payment — or, for a
  trial, that the trial started. Renewals, failures and cancellations arrive
  only as webhooks.

  Lifecycle:

    * A trial (`start_subscription/3`'s `:trial_days` option) grants the tier
      when Stripe reports the subscription `trialing`; the renewal after the
      trial is billed and granted like any other charge.
    * Cancelling keeps the tier until the paid period ends.
    * A failed renewal keeps the tier while Stripe retries; only Stripe giving
      up returns the account to free.
    * With no Stripe secret key configured, `start_subscription/3` grants the
      tier directly (`grant_without_stripe/2`) — the one exception, because
      no webhook will ever arrive.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Accounts, CodeMySpec.Repo, CodeMySpec.Users.Scope]

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
  Starts or changes a subscription for `tier` and returns the secret the browser
  confirms.

  Nothing about the account's plan changes here — see the moduledoc.

  ## One subscription per account, always

  An account with a billing subscription has that one *moved* to the new price
  rather than a second one created beside it: a duplicate bills the sum while
  our own data looks correct.

  "Billing" means a status in `@billing_statuses`. An `incomplete`
  subscription from an abandoned checkout charges nothing, so a fresh one is
  created beside it; Stripe expires those on its own. When the existing
  subscription cannot be read, this refuses (`:subscription_unreadable`)
  rather than risk a duplicate.
  """
  @spec start_subscription(Scope.t(), atom(), keyword()) ::
          {:ok, %{client_secret: String.t() | nil, subscription_id: String.t()}}
          | {:error, term()}
  def start_subscription(%Scope{} = scope, tier, opts \\ []) when tier in @tiers do
    if StripeClient.configured?() do
      buy_subscription(scope, tier, opts)
    else
      grant_without_stripe(scope, tier)
    end
  end

  defp buy_subscription(scope, tier, opts) do
    trial_days = Keyword.get(opts, :trial_days, 0)

    with {:ok, account} <- ensure_customer(scope) do
      # Reloaded, never taken from the scope: `stripe_subscription_id` is
      # written by a webhook after the page mounted.
      account = Accounts.get_account_by_id(account.id) || account

      case billing_subscription(account) do
        {:ok, existing} -> change_tier(account, existing, tier)
        :none -> create_subscription(account, tier, trial_days)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # No Stripe secret key configured (a fresh dev box): grant the tier directly
  # rather than gate the rest of the funnel on billing config. The one writer
  # of `account.plan` besides the webhook.
  defp grant_without_stripe(%Scope{active_account: %Account{id: id}}, tier) do
    Logger.info("[Billing] Stripe not configured — granting #{tier} directly for account #{id}")

    id
    |> Accounts.get_account_by_id()
    |> Ecto.Changeset.change(plan: tier)
    |> Repo.update()
    |> case do
      {:ok, _account} -> {:ok, %{client_secret: nil, subscription_id: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A trial has no invoice to confirm, so Stripe attaches a
  # `pending_setup_intent` instead; expanding both lets `client_secret/1` pick
  # whichever is present.
  defp create_subscription(account, tier, trial_days) do
    params = %{
      "customer" => account.stripe_customer_id,
      "items[0][price]" => price_id!(tier),
      "items[0][quantity]" => "1",
      # Leaves the subscription unpaid until the browser confirms, which
      # is what makes this embedded rather than a redirect.
      "payment_behavior" => "default_incomplete",
      "payment_settings[save_default_payment_method]" => "on_subscription",
      "metadata[account_id]" => account.id,
      "metadata[tier]" => to_string(tier),
      "expand[0]" => "latest_invoice.confirmation_secret",
      "expand[1]" => "pending_setup_intent"
    }

    params =
      if trial_days > 0,
        do: Map.put(params, "trial_period_days", to_string(trial_days)),
        else: params

    with {:ok, subscription} <- StripeClient.create_subscription(params) do
      client_secret(subscription)
    end
  end

  # `always_invoice`, not the default `create_prorations`: the Payment Element
  # needs something to confirm now, and the upgrade is billed now.
  defp change_tier(account, subscription, tier) do
    with {:ok, item_id} <- subscription_item_id(subscription),
         {:ok, updated} <-
           StripeClient.update_subscription(subscription["id"], %{
             "items[0][id]" => item_id,
             "items[0][price]" => price_id!(tier),
             "items[0][quantity]" => "1",
             "proration_behavior" => "always_invoice",
             "payment_behavior" => "default_incomplete",
             "payment_settings[save_default_payment_method]" => "on_subscription",
             "metadata[account_id]" => account.id,
             "metadata[tier]" => to_string(tier),
             "expand[0]" => "latest_invoice.confirmation_secret",
             "expand[1]" => "pending_setup_intent"
           }) do
      settled_or_confirmable(updated)
    end
  end

  # A downgrade's proration is a credit: Stripe returns no secret, and on a
  # successful update that means the change is done, not a failure.
  defp settled_or_confirmable(subscription) do
    case confirmable_secret(subscription) do
      {secret, intent_type} ->
        {:ok,
         %{client_secret: secret, subscription_id: subscription["id"], intent_type: intent_type}}

      nil ->
        {:ok, %{client_secret: nil, subscription_id: subscription["id"]}}
    end
  end

  # Statuses that take money; only these block a new subscription.
  @billing_statuses ~w(active trialing past_due unpaid paused)

  defp billing_subscription(%Account{stripe_subscription_id: id} = account) when is_binary(id) do
    case StripeClient.get_subscription(id) do
      {:ok, %{"status" => status} = subscription} when status in @billing_statuses ->
        {:ok, subscription}

      {:ok, %{"status" => status}} ->
        # Not billing — incomplete, canceled, expired. Logged so a duplicate
        # is diagnosable in one line.
        Logger.info(
          "[Billing] account #{account.id}: subscription #{id} is #{status}, " <>
            "not billing — creating a new one"
        )

        :none

      other ->
        # Refuse: a refused checkout is visible and retried; a duplicate
        # subscription is invisible from our data and bills monthly.
        # See knowledge/platform, "Billing".
        Logger.warning(
          "[Billing] account #{account.id}: could not read subscription #{id} " <>
            "(#{inspect(other)}) — refusing rather than risk a duplicate"
        )

        {:error, :subscription_unreadable}
    end
  end

  defp billing_subscription(%Account{id: id}) do
    Logger.info("[Billing] account #{id}: no subscription recorded — creating one")
    :none
  end

  # The item, not the price or the subscription — naming the wrong one adds a
  # second line to the subscription.
  defp subscription_item_id(subscription) do
    case get_in(subscription, ["items", "data"]) do
      [%{"id" => id} | _] -> {:ok, id}
      _ -> {:error, :no_subscription_item}
    end
  end

  defp client_secret(subscription) do
    case confirmable_secret(subscription) do
      {secret, intent_type} ->
        {:ok,
         %{client_secret: secret, subscription_id: subscription["id"], intent_type: intent_type}}

      nil ->
        # Without the expand there is no secret and the Payment Element has
        # nothing to confirm — a silent misconfiguration rather than a decline.
        {:error, :no_client_secret}
    end
  end

  # A real charge confirms a `latest_invoice`'s PaymentIntent; a trial with
  # nothing due today confirms the subscription's own `pending_setup_intent`
  # instead — collecting a card without charging it, so the renewal after the
  # trial has something to bill. Checked in that order because a subscription
  # can carry both once a trial has ended and a real invoice exists.
  defp confirmable_secret(subscription) do
    cond do
      secret = get_in(subscription, ["latest_invoice", "confirmation_secret", "client_secret"]) ->
        {secret, :payment}

      secret = get_in(subscription, ["pending_setup_intent", "client_secret"]) ->
        {secret, :setup}

      true ->
        nil
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
    if duplicate_event?(changeset) do
      Logger.info("[Billing] ignoring redelivered Stripe event #{event_id}")
      :ok
    else
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

  # Money moved. This and the trial start below are the only places a paid
  # tier is granted.
  defp handle("invoice.payment_succeeded", event) do
    with {:ok, account} <- account_for(event) do
      set_plan(account, tier_for(event) || account.plan, subscription_id(event))
    end
  end

  # A trial has nothing to invoice, so `invoice.payment_succeeded` fires only
  # when it ends. `trialing` on creation is what grants access for the trial.
  defp handle(
         "customer.subscription.created",
         %{"data" => %{"object" => %{"status" => "trialing"}}} = event
       ) do
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

  # A subscription event carries metadata at the top; an invoice carries the
  # subscription's under `parent.subscription_details`. Both must resolve, or
  # the event is deduped and grants nothing.
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
