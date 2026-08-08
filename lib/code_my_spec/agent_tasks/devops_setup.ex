defmodule CodeMySpec.AgentTasks.DevopsSetup do
  @moduledoc """
  One-time DevOps provisioning for a project (Story 858).

  The agent does all the user's DevOps: given Hetzner, AWS, and Cloudflare
  credentials collected once up front, it provisions a server, DNS, TLS,
  a secrets store, deploys, backups, and uptime monitoring — into the
  user's own accounts — and records the result at
  `.code_my_spec/devops/setup.md`.

  The pattern is the proven Kamal + kamal-proxy + SSM-bootstrap stack:

  - Kamal deploys a Docker image; kamal-proxy terminates TLS per host
    with auto-issued certificates.
  - App secrets are seeded to AWS SSM Parameter Store under
    `/<app>/<env>/<KEY>` and fetched by the app at boot via a generated
    `<App>.Secrets.load!/1`; the deploy tool carries only AWS bootstrap
    credentials.
  - Nightly `pg_dump` to S3 with expiry; UptimeRobot (or equivalent)
    monitor per public domain.

  Environments follow `ProjectConfiguration.devops` — one ordered level:
  `:off` (the graph never demands this task), `:uat` (staging only), or
  `:prod` (full UAT-then-prod, the default).
  """

  alias CodeMySpec.Configurations
  alias CodeMySpec.Resources
  alias CodeMySpec.Users.Scope

  @doc """
  One-line description surfaced by the requirement graph when this task is
  the next thing to do.
  """
  def dispatch(_node) do
    "Provision the project's infrastructure end to end — server, DNS, TLS, " <>
      "secrets store, deploys, backups, uptime monitoring — into the user's " <>
      "own accounts, recording the result at `.code_my_spec/devops/setup.md`. " <>
      "Use when code generation is complete and no verified DevOps setup " <>
      "record exists."
  end

  @doc """
  Generate the prompt for the DevOps setup session.
  """
  @spec command(Scope.t(), map()) :: {:ok, String.t()}
  def command(%Scope{} = scope, _task) do
    # `get/1`, not `get_or_create/1`. Building a prompt is a read, and seeding
    # a configuration row as a side effect of describing the work is how six of
    # them appeared from display paths alone.
    config = Configurations.get(scope)
    prod? = prod_enabled?(config)

    prompt =
      [
        header_section(),
        credentials_section(),
        environments_section(prod?),
        provisioning_section(prod?),
        secrets_section(),
        resilience_section(),
        repeatability_section(),
        failure_contract_section(),
        done_signal_section(prod?)
      ]
      |> Enum.join("\n\n")

    {:ok, prompt}
  end

  @doc """
  Evaluate: the setup record exists and attests a verified environment.

  The record is written by the agent at the END of setup — after every
  environment's health check has been verified live — so its presence plus
  the verification attestation is the completion signal. Multi-turn
  credential waits make this a manual-validation task; call `evaluate_task`
  when the record is in place.
  """
  @spec evaluate(Scope.t(), map()) :: {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(%Scope{} = scope, _task) do
    scope |> Resources.report() |> evaluate_report()
  end

  # Asks the providers what exists, rather than asking a file what it claims.
  #
  # This used to read `.code_my_spec/devops/setup.md` and grep it for the
  # strings "## Environments", "verified" and — with production on — "prod".
  # An agent that wrote a file containing the word "verified" satisfied the
  # requirement. Nothing checked that a server was running, a record resolved
  # or a bucket existed, so "devops setup is complete" was a claim about
  # prose.
  #
  # `Resources.report/1` already reconciles expected against actual across all
  # four providers, and already knows the difference between a step that never
  # ran and a resource pointing at nothing. Reusing it means the graph and the
  # page cannot disagree about whether setup is done, which they could when one
  # read providers and the other read a markdown file.
  defp evaluate_report(%{errors: errors}) when errors != %{} do
    # Not "incomplete" — unknown. A provider being unreachable says nothing
    # about whether setup happened, and reporting it as unsatisfied would make
    # a network blip look like undone work and invite someone to redo it.
    {:ok, :invalid,
     "Could not check " <>
       Enum.map_join(errors, ", ", fn {provider, reason} -> "#{provider} (#{inspect(reason)})" end) <>
       ". This is not a verdict on the setup — it is that the answer is not " <>
       "available right now. Re-run the check when the provider is reachable."}
  end

  defp evaluate_report(%{checklist: checklist}) do
    case Enum.filter(checklist, &(&1.state == :missing)) do
      [] ->
        {:ok, :valid}

      missing ->
        {:ok, :invalid,
         "Setup is not complete. Still missing: " <>
           Enum.map_join(missing, ", ", &"#{&1.project_name}/#{&1.key}") <>
           ". Each is a step whose resources are not there — run it from the " <>
           "provisioning page, or `Resources.fix_all/1` to build everything missing."}
    end
  end

  # :off never reaches this task (the graph filter drops the requirement);
  # anything unset or unknown gets the recommended full-promotion default.
  # No row means nothing has been configured, and the default is `:off` — so
  # production is not enabled. Reading a missing row as `:prod` was safe only
  # while `get_or_create/1` guaranteed a row existed.
  defp prod_enabled?(nil), do: false

  defp prod_enabled?(config) do
    (Map.get(config, :devops) || :off) == :prod
  end

  # ── Prompt sections ─────────────────────────────────────────────────

  defp header_section do
    """
    # DevOps Setup Session

    You are provisioning this project's infrastructure end to end. The user
    does the thinking; you do the labor. Everything you provision lives in
    the user's own accounts — you never route infrastructure through
    CodeMySpec-owned resources.\
    """
  end

  defp credentials_section do
    """
    ## Credentials — collected once, up front

    Ask the user for exactly three credentials, once, before any
    provisioning (use `ask_user` if they're not already in the environment):

    - **Hetzner** API token (server provisioning)
    - **AWS** access key pair (SSM Parameter Store secrets + S3 backups)
    - **Cloudflare** API token (DNS records in the user's zone)

    Account signup and payment are the user's job; from these tokens onward,
    every step is yours. Proceed through server, DNS, secrets, and deploy
    without further input or questions — the credentials are the only thing
    you need from the user.\
    """
  end

  defp environments_section(true = _prod?) do
    """
    ## Environments

    Stand up **UAT** (`uat.<domain>`) and **prod** (`<domain>`) — both by
    default. Each environment gets its own domain, its own database, and its
    own secrets namespace. The user can opt out of prod in project
    configuration; this project has it enabled.\
    """
  end

  defp environments_section(false) do
    """
    ## Environments

    This project has opted out of the second environment: stand up **UAT**
    (`uat.<domain>`) only. Give it its own domain, database, and secrets
    namespace. Nothing downstream should demand more than UAT.\
    """
  end

  defp provisioning_section(prod?) do
    targets = if prod?, do: "UAT and prod", else: "UAT"

    """
    ## Provisioning order

    1. **Server** — provision (or reuse) a Hetzner box; install Docker and
       `kamal-proxy` on :80/:443. The proxy terminates TLS with auto-issued
       Let's Encrypt certificates and routes by host — certificates are
       automatic, never touched by anyone.
    2. **DNS** — create the Cloudflare records for #{targets} in the user's
       zone (unproxied A records so HTTP-01 issuance works).
    3. **Database** — shared Postgres under `/opt/shared/` with one database
       per environment, provisioned by script.
    4. **Deploy** — Kamal config (`config/deploy.yml` per environment),
       Dockerfile, and a `/health` endpoint; build via CI to a registry and
       `kamal deploy` onto the box.
    5. **Verify** — after each environment deploys, request
       `https://<env-domain>/health` and confirm 200 over valid TLS before
       calling that environment done.\
    """
  end

  defp secrets_section do
    """
    ## Secrets — store-seeded, boot-fetched

    App secrets are seeded once into AWS SSM Parameter Store under
    `/<app>/<env>/<KEY>` and fetched by the app at boot: generate a
    `<App>.Secrets.load!/1` that loads every required key at startup. If a
    required secret is missing from the store, the app must fail fast —
    refuse to start, naming the missing key — rather than boot
    half-configured.

    Secret values never land in the repo and never pass through the deploy
    tool: the Kamal config carries only the AWS bootstrap credentials and
    `APP_ENV`/`AWS_REGION`. Nothing else.\
    """
  end

  defp resilience_section do
    """
    ## Backups and monitoring — part of setup, not an afterthought

    - **Backups**: nightly scheduled `pg_dump` per environment database,
      shipped to an S3 bucket in the user's account with an expiry
      (retention) policy, plus a short local rolling window on the box.
    - **Uptime monitoring**: one HTTP monitor per public domain (UptimeRobot
      or equivalent), created before setup is called done.\
    """
  end

  defp repeatability_section do
    """
    ## Everything is re-runnable

    Every infrastructure step is captured as configuration or scripts
    checked in (committed) to the repo — Kamal configs, provisioning
    scripts, secrets seeding, backup scheduling. Re-running any script must
    be safe and idempotent: it converges on the same state instead of
    duplicating resources. If you find yourself doing something that can't
    be replayed from the repo, script it first.\
    """
  end

  defp failure_contract_section do
    """
    ## Failure contract — halt and name it

    When a credential can't perform a step (permission or scope error from
    any provider), **halt** that step before any partial provisioning — do
    not continue into a half-provisioned state. Report exactly which
    credential failed and which permission it needs, then wait for the
    corrected credential. Never work around an authorization failure.\
    """
  end

  defp done_signal_section(prod?) do
    envs = if prod?, do: "both environments", else: "UAT"

    """
    ## Done signal

    Write `.code_my_spec/devops/setup.md` with an `## Environments` section
    listing each environment's domain and its live health check marked
    **verified** (a real 200 over TLS you observed, for #{envs}), plus the
    monitor and backup schedule you installed. Then call `evaluate_task` —
    the checker validates the record.\
    """
  end
end
