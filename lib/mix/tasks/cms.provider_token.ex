defmodule Mix.Tasks.Cms.ProviderToken do
  @shortdoc "Print a fresh access token for a connected provider, refreshing the live grant"

  @moduledoc """
  Emit a currently-valid access token for a connected provider, refreshing the
  grant first when the stored token is stale.

      MIX_ENV=test mix cms.provider_token cloudflare
      MIX_ENV=test mix cms.provider_token resend

  This exists so spex recording sources its tokens from the **live grant** the
  running app already keeps refreshed, rather than static `CMS_*_TOKEN` env
  vars. Cloudflare and Resend rotate their refresh token on every use, so a
  static env token goes dead the first time anything refreshes it — which is
  why recording used to demand a manual reconnect between runs. Here the refresh
  and the rotation both happen against the dev DB (`code_my_spec_dev`), so the
  grant stays alive and the next run just works.

  Run under `MIX_ENV=test`: it points `CodeMySpec.Repo` at the dev database but
  builds against the test artifacts, so it never contends for the dev compile
  lock the running `:4000` server holds. It touches dev *data*, not dev *code*.

  Only the fresh access token is written to stdout; everything else goes to
  stderr, so `CMS_CLOUDFLARE_TOKEN=$(MIX_ENV=test mix cms.provider_token cloudflare)`
  captures exactly the token.
  """
  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias CodeMySpec.Integrations
  alias CodeMySpec.Integrations.Integration
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.{Scope, User}

  import Ecto.Query

  @impl Mix.Task
  def run([provider_str]) do
    provider = String.to_existing_atom(provider_str)

    # Logger writes to stdout by default; the token is what stdout is for here.
    Logger.configure(level: :warning)

    # Point the default Repo at the dev DB with an ordinary pool (the test
    # config uses the SQL sandbox, which would hand out no real connection).
    repo_cfg =
      :code_my_spec
      |> Application.get_env(Repo, [])
      |> Keyword.merge(
        database: "code_my_spec_dev",
        pool: DBConnection.ConnectionPool,
        pool_size: 2,
        # stdout carries the token and nothing else, so it can be captured with
        # `$(...)`. Query logging would land in the middle of it.
        log: false
      )

    Application.put_env(:code_my_spec, Repo, repo_cfg)

    # The minimum to run a refresh: Req (Assent's HTTP adapter), Ecto/Postgrex
    # (which own DBConnection.Watcher, needed before Repo.start_link), the Cloak
    # vault that decrypts the stored tokens, and the Repo itself.
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = CodeMySpec.Vault.start_link()
    {:ok, _} = Repo.start_link()

    # Newest wins — except the copies a spex wrote. `connect_provider/3` stamps
    # every borrowed grant `provider_user_id: "spex"`, and a run pointed at
    # code_my_spec_dev writes that copy into the database this reads. It is
    # newer than the grant it was copied from, by milliseconds, and it travels
    # without its refresh token on purpose — so once one exists this task picked
    # it, found nothing to renew with, and reported `:reauthorize_required`
    # about a connection that was never broken.
    #
    # The same defect `refresh_dev_grant/1` has in the spex fixtures, in the
    # other place that reads this table.
    integration =
      Repo.one(
        from i in Integration,
          where: i.provider == ^provider,
          where:
            is_nil(fragment("?->>'provider_user_id'", i.provider_metadata)) or
              fragment("?->>'provider_user_id'", i.provider_metadata) != "spex",
          order_by: [desc: i.updated_at],
          limit: 1
      )

    unless integration do
      Mix.raise("no connected #{provider} integration in code_my_spec_dev")
    end

    scope = %Scope{user: Repo.get!(User, integration.user_id)}

    case Integrations.fetch_access_token(scope, provider) do
      {:ok, token} ->
        IO.puts(:stderr, "refreshed #{provider} for user ##{integration.user_id}")
        IO.puts(token)

      {:error, reason} ->
        Mix.raise("could not obtain a #{provider} token: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix cms.provider_token <cloudflare|resend|github>")
end
