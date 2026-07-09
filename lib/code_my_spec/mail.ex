defmodule CodeMySpec.Mail do
  @moduledoc """
  Email-on-your-domain: per-project mailboxes over a verified domain.

  Owns mailboxes and the persisted email history. Inbound is routed by the To
  address to a mailbox (catch-all fallback) and persisted; outbound is sent
  with the mailbox address as From and persisted too, so a mailbox's
  per-correspondent threads outlive the provider's ~30-day retention window.
  The provider (Resend) sits behind an adapter; this context is provider-
  agnostic. Not coupled to Conversations/chat.

  Visibility is account-role aware: owners and admins see every mailbox on the
  project; a plain member sees the shared mailboxes plus any assigned to them.
  """

  import Ecto.Query, warn: false
  require Logger

  alias CodeMySpec.Repo
  alias CodeMySpec.Accounts
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Mail.{Mailbox, Email, ResendClient, Attachments, EmailAttachment}
  alias CodeMySpec.Uploads
  alias CodeMySpec.Users.Scope

  # --- Mailboxes ---

  @doc "Create a mailbox on the active project (assigned via `user_id`, or shared when nil)."
  def create_mailbox(%Scope{} = scope, attrs) do
    attrs = Map.put(string_keyed(attrs), "project_id", scope.active_project_id)

    %Mailbox{}
    |> Mailbox.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Mailboxes the scope's member is allowed to see, by account role."
  def list_mailboxes(%Scope{} = scope) do
    scope
    |> visible_query()
    |> order_by([m], asc: m.address)
    |> Repo.all()
    |> Repo.preload(:user)
  end

  @doc "The project whose sending domain matches `domain`, or nil."
  def get_project_by_domain(domain) when is_binary(domain) do
    Repo.one(from p in Project, where: p.domain == ^domain, limit: 1)
  end

  def get_project_by_domain(_), do: nil

  # --- Domain onboarding (Resend) ---

  @doc """
  Register the project's sending domain with Resend and persist the domain name
  plus Resend's domain id. Returns `{:ok, project, records}` where `records` are
  the DNS records the operator must publish, or `{:error, reason}`.
  """
  def setup_domain(%Scope{} = scope, %Project{} = project, domain_name)
      when is_binary(domain_name) do
    domain_name = String.trim(domain_name)

    with {:ok, body} <- find_or_create_domain(domain_name),
         {:ok, project} <- Projects.update_project(scope, project, domain_attrs(domain_name, body)) do
      {:ok, project, records(body)}
    end
  end

  # Resend rejects re-creating a domain the account already has (403/409/422).
  # Adopt the existing one so setup is idempotent across retries and shared
  # domains, fetching its full record (incl. DNS records) by id.
  defp find_or_create_domain(name) do
    case ResendClient.create_domain(name) do
      {:ok, body} ->
        {:ok, body}

      {:error, {:resend_error, status, _}} = error when status in [403, 409, 422] ->
        case ResendClient.find_domain_by_name(name) do
          {:ok, domain} -> ResendClient.get_domain(domain["id"])
          :not_found -> error
          {:error, _} = list_error -> list_error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp domain_attrs(name, body) do
    verified_at =
      if body["status"] == "verified",
        do: DateTime.utc_now() |> DateTime.truncate(:second),
        else: nil

    %{domain: name, resend_domain_id: body["id"], domain_verified_at: verified_at}
  end

  @doc """
  Read the current DNS records and provider status for the project's domain.
  Returns `{:ok, records, status}` or `{:error, reason}`.
  """
  def domain_dns_records(%Project{resend_domain_id: id}) when is_binary(id) do
    case ResendClient.get_domain(id) do
      {:ok, body} -> {:ok, records(body), body["status"]}
      {:error, reason} -> {:error, reason}
    end
  end

  def domain_dns_records(_project), do: {:error, :no_domain}

  @doc """
  Ask Resend to (re-)verify the project's domain. When Resend reports the domain
  as `"verified"`, stamps `domain_verified_at` so mail can flow. Returns
  `{:ok, project, status}` (status is `:verified` or the provider's raw status)
  or `{:error, reason}`.
  """
  def verify_domain(%Scope{} = scope, %Project{resend_domain_id: id} = project)
      when is_binary(id) do
    with {:ok, _} <- ResendClient.verify_domain(id),
         {:ok, body} <- ResendClient.get_domain(id) do
      case body["status"] do
        "verified" ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          {:ok, project} = Projects.update_project(scope, project, %{domain_verified_at: now})
          {:ok, project, :verified}

        status ->
          {:ok, project, status}
      end
    end
  end

  def verify_domain(_scope, _project), do: {:error, :no_domain}

  defp records(%{"records" => records}) when is_list(records), do: records
  defp records(_body), do: []

  def get_mailbox(%Scope{} = scope, id) do
    Repo.get_by(Mailbox, id: id, project_id: scope.active_project_id)
  end

  def catch_all_mailbox(project_id) do
    Repo.one(from m in Mailbox, where: m.project_id == ^project_id and m.catch_all == true, limit: 1)
  end

  # --- Inbound / outbound ---

  @doc """
  Route an inbound provider event to a mailbox and persist it. Matches the To
  address to a mailbox on the project, falling back to the project's catch-all.

  The `email.received` webhook is metadata-only, so when the body isn't carried
  in the event we fetch it from the Receiving API using the provider's email id.
  Returns `{:ok, %Email{}}` or `{:error, :no_mailbox}` when nothing matches.
  """
  def route_inbound(%Project{} = project, attrs) do
    to = attrs |> Map.get(:to) |> List.wrap() |> List.first()
    from = Map.get(attrs, :from)
    provider_email_id = Map.get(attrs, :provider_email_id)

    case match_mailbox(project.id, to) do
      nil ->
        {:error, :no_mailbox}

      %Mailbox{} = mailbox ->
        {text, html} = resolve_inbound_body(attrs, provider_email_id)

        %Email{}
        |> Email.changeset(%{
          direction: :inbound,
          mailbox_id: mailbox.id,
          from_address: from,
          to_address: to,
          correspondent: from,
          subject: Map.get(attrs, :subject),
          body_text: text,
          body_html: html,
          provider_id: provider_email_id,
          message_id: Map.get(attrs, :message_id),
          in_reply_to: Map.get(attrs, :in_reply_to)
        })
        |> Repo.insert()
        |> tap_store_attachments(attrs)
    end
  end

  # Resend strips inbound attachment bytes from the webhook, so when the event
  # names any, copy them out of the provider into our bucket. Best-effort: the
  # email is already persisted, so a storage failure never fails the insert.
  defp tap_store_attachments({:ok, %Email{} = email} = ok, attrs) do
    case Map.get(attrs, :attachments) do
      [_ | _] -> Attachments.store_inbound(email)
      _ -> :ok
    end

    ok
  end

  defp tap_store_attachments(other, _attrs), do: other

  # Use the body carried in the event when present (tests / future inline
  # payloads); otherwise fetch it from the Receiving API by id.
  defp resolve_inbound_body(attrs, provider_email_id) do
    text = Map.get(attrs, :text)
    html = Map.get(attrs, :html)

    if is_nil(text) and is_nil(html) and is_binary(provider_email_id) do
      case ResendClient.get_received_email(provider_email_id) do
        {:ok, body} ->
          {body["text"], body["html"]}

        {:error, reason} ->
          Logger.warning("Mail.route_inbound: could not fetch body for #{provider_email_id}: #{inspect(reason)}")
          {nil, nil}
      end
    else
      {text, html}
    end
  end

  @doc """
  Reconcile inbound mail for a project against the provider's Receiving API —
  the catch-up companion to the (at-least-once, sometimes-missed) webhook.

  Lists received emails, routes any the project never recorded into their
  mailbox (fetching the body), and backfills bodies onto rows that were stored
  metadata-only. Idempotent by Message-ID. Bounded to the provider's retention
  window and the requested page size.

  Returns `{:ok, %{synced: total_seen, new: inserted, backfilled: updated}}`.
  """
  def sync_inbound(%Project{} = project, opts \\ []) do
    case ResendClient.list_received_emails(opts) do
      {:ok, received} ->
        tally =
          Enum.reduce(received, %{synced: 0, new: 0, backfilled: 0}, fn meta, acc ->
            acc = %{acc | synced: acc.synced + 1}

            case reconcile_received(project, meta) do
              :inserted -> %{acc | new: acc.new + 1}
              :backfilled -> %{acc | backfilled: acc.backfilled + 1}
              _ -> acc
            end
          end)

        {:ok, tally}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_received(project, meta) do
    message_id = meta["message_id"]
    existing = message_id && Repo.get_by(Email, message_id: message_id)

    cond do
      is_nil(existing) -> insert_received(project, meta)
      blank_body?(existing) -> backfill_body(existing, meta)
      true -> :skipped
    end
  end

  defp insert_received(project, meta) do
    case route_inbound(project, %{
           from: meta["from"],
           to: meta["to"],
           subject: meta["subject"],
           message_id: meta["message_id"],
           provider_email_id: meta["id"],
           attachments: meta["attachments"]
         }) do
      {:ok, _email} -> :inserted
      {:error, :no_mailbox} -> :no_mailbox
      # Lost a race (webhook delivered it concurrently) — already recorded.
      {:error, _changeset} -> :skipped
    end
  end

  defp backfill_body(%Email{} = email, meta) do
    case ResendClient.get_received_email(meta["id"]) do
      {:ok, body} ->
        {:ok, updated} =
          email
          |> Email.changeset(%{body_text: body["text"], body_html: body["html"], provider_id: meta["id"]})
          |> Repo.update()

        # Backfill attachments too if this row predates them being copied out.
        case body["attachments"] do
          [_ | _] -> Attachments.store_inbound(updated)
          _ -> :ok
        end

        :backfilled

      {:error, _reason} ->
        :skipped
    end
  end

  defp blank_body?(%Email{body_text: text, body_html: html}) do
    blank?(text) and blank?(html)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""

  @doc "Persist an outbound email sent from a mailbox (From = the mailbox address)."
  def record_outbound(%Mailbox{} = mailbox, attrs) do
    %Email{}
    |> Email.changeset(%{
      direction: :outbound,
      mailbox_id: mailbox.id,
      from_address: mailbox.address,
      to_address: Map.get(attrs, :to),
      correspondent: Map.get(attrs, :to),
      subject: Map.get(attrs, :subject),
      body_text: Map.get(attrs, :body)
    })
    |> Repo.insert()
  end

  @doc """
  Send an outbound email from a mailbox: persist it (From = the mailbox
  address) and hand it to the mail provider. Delivery is best-effort — the
  persisted copy is the source of truth for the mailbox's history.
  """
  def send_outbound(%Mailbox{} = mailbox, attrs) do
    with {:ok, email} <- record_outbound(mailbox, attrs) do
      {:ok, deliver(mailbox, email, attrs)}
    end
  end

  # Mailbox mail always goes through Resend's API (the whole point of the
  # feature — send on the project's own verified domain), independent of the
  # app's transactional Swoosh mailer, which is the local preview adapter in
  # dev. Delivery is best-effort: the persisted copy is the source of truth, so
  # a provider failure is logged, not surfaced as an error to the caller.
  defp deliver(%Mailbox{} = mailbox, %Email{} = email, attrs) do
    case ResendClient.send_email(%{
           from: mailbox.address,
           to: Map.get(attrs, :to),
           subject: Map.get(attrs, :subject) || "",
           text: Map.get(attrs, :body) || ""
         }) do
      {:ok, %{"id" => provider_id}} when is_binary(provider_id) ->
        store_provider_id(email, provider_id)

      {:ok, _body} ->
        email

      {:error, :resend_not_configured} ->
        Logger.debug("Mail.send_outbound: Resend not configured; persisted without delivery")
        email

      {:error, reason} ->
        Logger.warning("Mail.send_outbound delivery failed for mailbox #{mailbox.id}: #{inspect(reason)}")
        email
    end
  end

  defp store_provider_id(%Email{} = email, provider_id) do
    case email |> Email.changeset(%{provider_id: provider_id}) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _changeset} -> email
    end
  end

  # --- Emails / threads ---

  def list_emails(%Mailbox{} = mailbox) do
    Repo.all(
      from e in Email,
        where: e.mailbox_id == ^mailbox.id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
    |> Repo.preload(:attachments)
  end

  @doc """
  Fetch an attachment by id, scoped to a mailbox the current member may see, so
  one member can't pull another project's files. Returns the `EmailAttachment`
  or `nil`.
  """
  def get_attachment(%Scope{} = scope, id) do
    visible_ids = visible_query(scope) |> select([m], m.id)

    Repo.one(
      from a in EmailAttachment,
        join: e in Email,
        on: e.id == a.email_id,
        where: a.id == ^id and e.mailbox_id in subquery(visible_ids)
    )
  end

  @doc "A short-lived presigned URL to download an attachment's bytes from S3."
  def attachment_download_url(%EmailAttachment{s3_key: key}) when is_binary(key) do
    Uploads.presigned_download_url(key)
  end

  @doc """
  Emails grouped into threads keyed by **correspondent + normalized subject**,
  most-recently-active first. `Re:`/`Fwd:` prefixes are stripped when keying so
  replies thread with their original, but two different subjects with the same
  correspondent are distinct threads. Each thread carries a stable `key` (for
  selection), the `correspondent`, the original `subject`, its `emails`
  (oldest-first), and `last_at`.
  """
  def list_threads(%Mailbox{} = mailbox) do
    mailbox
    |> list_emails()
    |> Enum.group_by(fn email -> {email.correspondent, base_subject(email.subject)} end)
    |> Enum.map(fn {{correspondent, base}, emails} ->
      first = List.first(emails)
      latest = List.last(emails)

      %{
        key: Integer.to_string(:erlang.phash2({correspondent, base})),
        correspondent: correspondent,
        subject: (first && first.subject) || (latest && latest.subject),
        emails: emails,
        last_at: latest && latest.inserted_at
      }
    end)
    |> Enum.sort_by(& &1.last_at, {:desc, DateTime})
  end

  @doc "Normalizes a subject for threading: strips Re:/Fwd: prefixes, trims, downcases."
  def base_subject(nil), do: ""

  def base_subject(subject) when is_binary(subject) do
    subject
    |> String.replace(~r/^(\s*(re|fwd|fw)\s*:\s*)+/i, "")
    |> String.trim()
    |> String.downcase()
  end

  @doc "True when the scope's user may create and administer mailboxes (owner/admin)."
  def can_administer?(%Scope{} = scope), do: owner_or_admin?(scope)

  # --- private ---

  defp match_mailbox(project_id, nil), do: catch_all_mailbox(project_id)

  defp match_mailbox(project_id, address) do
    Repo.one(from m in Mailbox, where: m.project_id == ^project_id and m.address == ^address, limit: 1) ||
      catch_all_mailbox(project_id)
  end

  defp visible_query(%Scope{} = scope) do
    project_id = scope.active_project_id
    base = from m in Mailbox, where: m.project_id == ^project_id

    if owner_or_admin?(scope) do
      base
    else
      uid = scope.user.id
      from m in base, where: is_nil(m.user_id) or m.user_id == ^uid
    end
  end

  defp owner_or_admin?(%Scope{} = scope) do
    case Accounts.get_user_role(scope, scope.user.id, scope.active_account_id) do
      role when role in [:owner, :admin] -> true
      {:ok, role} when role in [:owner, :admin] -> true
      _ -> false
    end
  end

  defp string_keyed(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
