defmodule CodeMySpec.Repo.Migrations.AddBillingToAccountsAndStripeEvents do
  use Ecto.Migration

  # Three tiers, added alongside :paid rather than replacing it. :paid is
  # already persisted in dev and prod, and deciding what those accounts become
  # is a product question nobody has to answer to ship charging — so the value
  # stays valid and the decision waits for the gating story.
  #
  # Postgres enums are not used here: `plan` is a string column with an
  # Ecto.Enum on the schema, so adding values is a schema change and not a
  # migration at all. This migration only adds the billing columns.
  def change do
    alter table(:accounts) do
      # One Stripe Customer per account, reused forever. Passing `customer=`
      # rather than `customer_email=` is what stops Stripe minting duplicates.
      add :stripe_customer_id, :string
      add :stripe_subscription_id, :string
    end

    create unique_index(:accounts, [:stripe_customer_id])

    # One row per Stripe event id, inserted before the event is dispatched.
    # Stripe delivers at least once, so without this a redelivery would grant
    # or bill a second time.
    create table(:stripe_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, :string, null: false
      add :type, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:stripe_events, [:event_id])
  end
end
