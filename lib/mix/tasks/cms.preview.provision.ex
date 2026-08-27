defmodule Mix.Tasks.Cms.Preview.Provision do
  @shortdoc "Provision the preview tunnel for a project's main working copy"

  @moduledoc """
  Give a project's main checkout an address its preview answers on.

      mix cms.preview.provision <project_id>

  Prints the credentials the checkout needs to run the tunnel. They are also
  recorded on the working copy, so this is safe to run again: a copy that
  already holds a tunnel gets the same one back rather than a second.

  Deliberately a task rather than something onboarding always does. Creating a
  tunnel is a real record in a real Cloudflare account, and most checkouts are
  never previewed — `PreviewAddress` makes the same argument about DNS records
  and calls them "zone litter with a lifetime of forever". This runs when
  somebody asks for a preview.
  """

  use Mix.Task

  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewTunnel

  @requirements ["app.start"]

  @impl Mix.Task
  def run([project_id]) do
    case WorkingCopies.main(%Scope{active_project_id: project_id}) do
      nil ->
        Mix.raise("""
        #{project_id} has no main working copy.

        The preview runs where the project runs, and nothing has been
        designated. Onboard the checkout that serves this project first.
        """)

      copy ->
        provision(copy)
    end
  end

  def run(_args), do: Mix.raise("usage: mix cms.preview.provision <project_id>")

  defp provision(copy) do
    case PreviewTunnel.ensure(copy) do
      {:ok, creds} ->
        report(copy, creds)

      {:error, :no_cloudflare_account_id} ->
        Mix.raise("""
        No Cloudflare account id configured.

        Creating a tunnel is an account operation. Set CLOUDFLARE_ACCOUNT_ID —
        the zone-scoped CLOUDFLARE_TOKEN cannot discover it, because it returns
        an empty list from GET /accounts.
        """)

      {:error, :not_the_main_copy} ->
        Mix.raise("that working copy is not the project's main checkout")

      {:error, reason} ->
        Mix.raise("could not provision the preview tunnel: #{inspect(reason)}")
    end
  end

  # Printed rather than written into the checkout's config from here, because
  # the checkout may be on another machine. The secret is shown once for the
  # same reason Cloudflare shows it once — it is stored encrypted on the
  # working copy and this is the moment somebody can copy it.
  defp report(copy, creds) do
    Mix.shell().info("""

    Preview provisioned for #{copy.root || copy.id}

      address:     https://#{creds.hostname}
      hostname:    #{creds.hostname}
      tunnel:      #{creds.tunnel_id}
      account tag: #{creds.account_tag}

    In the app's supervision tree:

        {ClientUtils.CloudflareTunnel,
          mode: :named,
          hostname: "#{creds.hostname}",
          tunnel_id: "#{creds.tunnel_id}",
          account_tag: "#{creds.account_tag}",
          tunnel_secret: System.fetch_env!("PREVIEW_TUNNEL_SECRET"),
          origin_url: "http://127.0.0.1:4000",
          endpoint: MyAppWeb.Endpoint,
          otp_app: :my_app}

    PREVIEW_TUNNEL_SECRET=#{creds.tunnel_secret}
    """)
  end
end
