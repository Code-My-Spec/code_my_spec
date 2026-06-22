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

  alias CodeMySpec.Repo
  alias CodeMySpec.Accounts
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Mail.{Mailbox, Email, ResendClient}
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

    with {:ok, body} <- ResendClient.create_domain(domain_name),
         {:ok, project} <-
           Projects.update_project(scope, project, %{
             domain: domain_name,
             resend_domain_id: body["id"],
             domain_verified_at: nil
           }) do
      {:ok, project, records(body)}
    end
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
  Returns `{:ok, %Email{}}` or `{:error, :no_mailbox}` when nothing matches.
  """
  def route_inbound(%Project{} = project, attrs) do
    to = attrs |> Map.get(:to) |> List.wrap() |> List.first()
    from = Map.get(attrs, :from)

    case match_mailbox(project.id, to) do
      nil ->
        {:error, :no_mailbox}

      %Mailbox{} = mailbox ->
        %Email{}
        |> Email.changeset(%{
          direction: :inbound,
          mailbox_id: mailbox.id,
          from_address: from,
          to_address: to,
          correspondent: from,
          subject: Map.get(attrs, :subject),
          body_text: Map.get(attrs, :text),
          body_html: Map.get(attrs, :html),
          message_id: Map.get(attrs, :message_id),
          in_reply_to: Map.get(attrs, :in_reply_to)
        })
        |> Repo.insert()
    end
  end

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
      _ = deliver(mailbox, attrs)
      {:ok, email}
    end
  end

  defp deliver(%Mailbox{} = mailbox, attrs) do
    swoosh_email =
      Swoosh.Email.new()
      |> Swoosh.Email.from(mailbox.address)
      |> Swoosh.Email.to(Map.get(attrs, :to) || "")
      |> Swoosh.Email.subject(Map.get(attrs, :subject) || "")
      |> Swoosh.Email.text_body(Map.get(attrs, :body) || "")

    case CodeMySpec.Mailer.deliver(swoosh_email) do
      {:ok, meta} -> {:ok, meta}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Emails / threads ---

  def list_emails(%Mailbox{} = mailbox) do
    Repo.all(
      from e in Email,
        where: e.mailbox_id == ^mailbox.id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  @doc "Emails grouped into per-correspondent threads."
  def list_threads(%Mailbox{} = mailbox) do
    mailbox
    |> list_emails()
    |> Enum.group_by(& &1.correspondent)
    |> Enum.map(fn {correspondent, emails} -> %{correspondent: correspondent, emails: emails} end)
  end

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
