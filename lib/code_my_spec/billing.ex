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
  Starts or changes a subscription for `tier` and returns the secret the browser
  confirms.

  Nothing about the account's plan changes here — see the moduledoc.

  ## One subscription per account, always

  An account that already has a billing subscription has that one *moved* to the
  new price rather than a second one created beside it. `27f519dc`: creating
  unconditionally left both live, Stripe billed the sum, and our own data looked
  perfect throughout — one `stripe_subscription_id`, the right `plan` — because
  the older subscription simply stopped being referenced by anything we store.
  The only place the truth existed was Stripe.

  "Already has" means a subscription in a status that bills. A subscription left
  `incomplete` by an abandoned checkout charges nothing, so it is not what this
  guards against and a fresh one is created beside it; Stripe expires those on
  its own.
  """
  @spec start_subscription(Scope.t(), atom()) ::
          {:ok, %{client_secret: String.t(), subscription_id: String.t()}} | {:error, term()}
  def start_subscription(%Scope{} = scope, tier) when tier in @tiers do
    with {:ok, account} <- ensure_customer(scope) do
      # Reloaded, never taken from the scope. `scope.active_account` is a
      # snapshot from when the page mounted, and `stripe_subscription_id` is
      # written by a *webhook* — so between mount and click the struct in hand
      # is exactly the one that has not heard about the subscription yet.
      #
      # The first attempt at this fix read the scope's copy and shipped looking
      # correct: unit tests passed, because they built the account themselves.
      # Against real Stripe it created a second subscription every time, in both
      # directions, because the field it branched on was nil (`5a5708a7`).
      account = Accounts.get_account_by_id(account.id) || account

      case billing_subscription(account) do
        {:ok, existing} -> change_tier(account, existing, tier)
        :none -> create_subscription(account, tier)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_subscription(account, tier) do
    with {:ok, subscription} <-
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

  # `always_invoice` rather than the default `create_prorations`: the browser is
  # sitting on a Payment Element waiting for something to confirm, and deferring
  # the proration to the next cycle would leave it with nothing. This bills the
  # difference now, which is also what someone clicking "upgrade" expects.
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
             "expand[0]" => "latest_invoice.confirmation_secret"
           }) do
      settled_or_confirmable(updated)
    end
  end

  # A tier change does not always need paying for.
  #
  # `always_invoice` bills the proration immediately, and on an *upgrade* that
  # is a charge with a secret for the Payment Element to confirm. On a
  # downgrade it is a credit — nothing to collect, so Stripe returns no
  # `confirmation_secret`, and treating that as `:no_client_secret` told the
  # user "Stripe didn't give us a way to take the payment" about a change that
  # had already succeeded (`d5befe3c`).
  #
  # So the two are distinguished here rather than at the call site: a secret
  # means confirm it, no secret on a *successful* update means the change is
  # done and there is nothing to pay.
  defp settled_or_confirmable(subscription) do
    case get_in(subscription, ["latest_invoice", "confirmation_secret", "client_secret"]) do
      secret when is_binary(secret) ->
        {:ok, %{client_secret: secret, subscription_id: subscription["id"]}}

      _ ->
        {:ok, %{client_secret: nil, subscription_id: subscription["id"]}}
    end
  end

  # Statuses that take money. `incomplete` and `incomplete_expired` never
  # charged, and `canceled` has stopped — none of them can double-bill, so none
  # of them should block a new subscription.
  @billing_statuses ~w(active trialing past_due unpaid paused)

  defp billing_subscription(%Account{stripe_subscription_id: id} = account) when is_binary(id) do
    case StripeClient.get_subscription(id) do
      {:ok, %{"status" => status} = subscription} when status in @billing_statuses ->
        {:ok, subscription}

      {:ok, %{"status" => status}} ->
        # Not billing — incomplete, canceled, expired. Proceeding is right, and
        # saying so is what makes the next duplicate diagnosable in one line
        # instead of by driving real purchases against real Stripe.
        Logger.info(
          "[Billing] account #{account.id}: subscription #{id} is #{status}, " <>
            "not billing — creating a new one"
        )

        :none

      other ->
        # Refuse. This used to create, on the reasoning that declining a sale
        # because Stripe blipped is worse than a duplicate subscription.
        #
        # That was wrong, and QA proved it against real Stripe rather than in
        # argument: a DNS failure reading the subscription hit this branch twice
        # on one account, and the second time the create succeeded — leaving two
        # active subscriptions, the old one orphaned and still charging. The
        # exact defect `27f519dc` describes, arriving through the fallback meant
        # to be the safe side of the trade (`5a5708a7`).
        #
        # The two outcomes are not comparable. A refused checkout is visible
        # immediately, costs nothing, and the customer retries. A duplicate
        # subscription is invisible to us — our own data looks correct — and
        # bills every month until a human reads Stripe. So when we cannot tell
        # whether an account already pays, we do not sell.
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

  # The item, not the price and not the subscription. Naming the wrong one adds
  # a second line to the same subscription rather than replacing the first —
  # the same defect one level down, and just as invisible from our side.
  defp subscription_item_id(subscription) do
    case get_in(subscription, ["items", "data"]) do
      [%{"id" => id} | _] -> {:ok, id}
      _ -> {:error, :no_subscription_item}
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
