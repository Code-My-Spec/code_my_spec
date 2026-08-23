defmodule CodeMySpecWeb.ProvisioningLive do
  @moduledoc """
  The setup status page — the whole sequence, in order, with where it stands.

  ## The page shows the plan before it shows progress

  Every step Sam's options include is on screen from mount, `:not_started`,
  with the reason it exists. He sees the shape of the run before anything has
  happened (criterion 7959), rather than steps appearing one at a time as they
  execute, which would make the run unpredictable exactly when he most wants
  to know what it is about to do.

  A step his options exclude is absent, not present-and-greyed (criterion
  7968). Greying it out still reads as part of the run.

  ## State is asked for, not remembered

  Running a step verifies against the provider first — `Provisioning.run_step/3`
  does that, and this page does not second-guess it by filtering on the stored
  state. That is what makes a retry converge rather than duplicate, and a
  resource deleted behind setup's back get rebuilt.

  ## Paused and errored render differently on purpose

  A paused step shows what Sam must do elsewhere; an errored one shows what
  the provider actually said, so the escalation an agent picks up carries the
  detail that names the fix rather than "the step failed".

  ## Pasted credentials live here, not on the account page

  Cloudflare, Resend and GitHub are OAuth grants and belong on
  `/users/settings` — they are the user's, and one grant covers every project.
  Hetzner has no OAuth at all: it issues project-scoped API tokens, and its
  object-storage keys exist only in the console. Those are pasted secrets, and
  they are **per project**, so they belong on this page rather than on a
  user-scoped one where switching projects would silently mean the wrong
  account.

  Rendering them as a "Connect Hetzner" button next to the OAuth ones would be
  worse than leaving them out: identical affordance, completely different
  mechanism, and no consent screen on the other side.

  A stored value is never rendered back — the form says whether a secret is
  set, never what it is.
  """

  use CodeMySpecWeb, :live_view

  require Logger

  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.Projects
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning

  alias CodeMySpec.Provisioning.{
    Backups,
    Cloudflare,
    ContentPublishing,
    Credentials,
    Dns,
    Hetzner,
    Resend,
    Sops,
    Steps,
    Storage,
    Teardown,
    Widget
  }

  alias CodeMySpec.Users.Scope

  # The environments setup manages. Named once so the probe form, the resource
  # grouping and the storage step cannot disagree about what exists.

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.header>
      Setup
      <:subtitle>
        Everything your project needs, in the order it needs it.
      </:subtitle>
      <:actions>
        <.button data-test="generate-project" phx-click="generate_project" class="btn-ghost">
          Generate deploy files
        </.button>
        <.button data-test="start-setup" phx-click="start_setup">Run setup</.button>
        <.button :if={@halted_at} data-test="resume-setup" phx-click="resume_setup">
          Resume
        </.button>
      </:actions>
    </.header>

    <form data-test="setup-options-form" phx-change="toggle_options" class="my-6">
      <div class="flex flex-wrap gap-4">
        <label :for={option <- @available_options} class="label cursor-pointer gap-2">
          <input
            type="checkbox"
            class="checkbox"
            name={"options[#{option}]"}
            value="true"
            checked={option in @options}
          />
          <span class="label-text">{option}</span>
        </label>
      </div>
    </form>

    <section data-test="provider-credentials" class="my-6">
      <h2 class="text-lg font-semibold">Provider credentials</h2>
      <p class="opacity-70 text-sm">
        Everything this run needs, in one place. Hetzner has no OAuth — those are
        pasted and belong to this project. Cloudflare, Resend and GitHub are
        connected on <.link navigate={~p"/app/users/settings"} class="link">your account</.link>.
      </p>

      <div
        :if={@missing_credentials != []}
        data-test="credentials-incomplete"
        data-missing={Enum.map_join(@missing_credentials, ",", & &1.key)}
        class="alert alert-warning mt-3"
      >
        Setup cannot start yet — still needed: {Enum.map_join(@missing_credentials, ", ", & &1.label)}.
      </div>

      <form
        data-test="credentials-form"
        phx-submit="save_credentials"
        class="mt-3 flex flex-col gap-4"
      >
        <div
          :for={credential <- @credentials}
          data-test="credential-field"
          data-credential={credential.key}
          data-credential-kind={to_string(credential.kind)}
          data-stored={to_string(credential.stored?)}
          data-state={credential.state}
          class="flex flex-col gap-1"
        >
          <label class="label" for={credential.key}>
            <span class="label-text">{credential.label}</span>
            <span
              data-test="credential-state"
              data-key={credential.key}
              data-set={to_string(credential.stored?)}
              class={[
                "badge badge-sm",
                credential.state == "verified" && "badge-success",
                credential.state == "rejected" && "badge-error"
              ]}
            >
              {credential_badge(credential)}
            </span>
          </label>

          <input
            :if={credential.kind == :secret}
            type="password"
            id={credential.key}
            name={"credentials[#{credential.key}]"}
            data-test="credential-input"
            class="input input-bordered w-full"
            autocomplete="off"
            placeholder={
              if credential.stored?, do: "•••••••• (leave blank to keep)", else: credential.hint
            }
          />

          <p
            :if={credential.state == "rejected"}
            data-test="credential-rejection"
            data-credential={credential.key}
            class="text-xs text-error"
          >
            Rejected by the provider. Missing: {credential.missing_permission}
          </p>

          <p
            data-test="credential-directions"
            data-credential={credential.key}
            class="text-xs opacity-70"
          >
            {credential.directions}
          </p>

          <p class="text-xs opacity-50">{credential.why}</p>
        </div>

        <div class="flex gap-2">
          <.button type="submit" data-test="save-credentials">Save credentials</.button>
          <.button type="button" data-test="check-credentials" phx-click="check_credentials">
            Check them against the providers
          </.button>
        </div>
      </form>
    </section>

    <section data-test="domain" class="my-6">
      <h2 class="text-lg font-semibold">Domain</h2>
      <%!-- Describes what actually happens. It used to say "check a name, see
            what it costs, then say yes" — and steps two and three were
            unreachable for every input. Cloudflare's Registrar API returns a
            price and an availability answer only for domains already on the
            account; for anything else it returns the name and whether the TLD
            is supported, and nothing more. So a name you do not own can never
            be priced here, and a name you do own has no price to show.
            Advertising the flow the API cannot support read as a broken
            feature rather than a provider limitation. --%>
      <p class="opacity-70 text-sm">
        Bring a domain you already own and check it here to adopt it. To register a new
        one, buy it in the Cloudflare dashboard and come back — the Registrar API will
        not price or sell a name this app does not already hold.
      </p>

      <form data-test="domain-form" phx-submit="check_domain" class="mt-3 flex gap-2 items-end">
        <label class="form-control">
          <span class="label-text text-xs">Domain</span>
          <input
            type="text"
            name="domain[name]"
            value={@domain_name}
            class="input input-bordered input-sm"
            placeholder="example.com"
          />
        </label>
        <.button type="submit" data-test="check-domain">Check</.button>
      </form>

      <div :if={@domain_check} class="mt-3 flex flex-col gap-2">
        <!-- Availability as the registrar actually reports it. For a name the
             account does not already hold, Cloudflare answers only whether the
             TLD is supported — not a price and not a definite yes — so the
             three states are `available`, `taken`, and `unknown`, and
             `unknown` is not `taken` (criterion 7988's reground). -->
        <span
          data-test="domain-availability"
          data-availability={to_string(@domain_check.availability)}
          data-available={to_string(@domain_check.availability == :available)}
          data-supported-tld={to_string(@domain_check.supported_tld)}
          data-name={@domain_name}
          class={[
            "badge",
            @domain_check.availability == :available && "badge-success",
            @domain_check.availability == :taken && "badge-error"
          ]}
        >
          {availability_label(@domain_check)}
        </span>
        
    <!-- A taken name is a dead end here: choose another (criterion 7989). -->
        <p :if={@domain_check.availability == :taken} data-test="domain-taken" class="text-sm">
          {@domain_name} is already registered{if @domain_check.current_registrar,
            do: " (#{@domain_check.current_registrar})"}. Pick another name.
        </p>
        
    <!-- The API can price and sell only a name the account can already act
             on. Those rare cases keep the in-app confirm. -->
        <span
          :if={@domain_check.availability == :available and @domain_check.price}
          data-test="domain-price"
          class="text-sm"
        >
          {@domain_check.price} {@domain_check.currency}
        </span>

        <.button
          :if={@domain_check.availability == :available and @domain_check.price}
          data-test="confirm-purchase"
          phx-click="confirm_purchase"
          class="btn-warning w-fit"
        >
          Yes — register {@domain_name}
        </.button>
        
    <!-- The common new-name case: a supported TLD the API will not price
             or sell. Buying is a Cloudflare dashboard errand, not an in-app
             purchase (criteria 7988, 7990, 7993, 7994) — and setup adopts it
             once it is registered and its records resolve. -->
        <div
          :if={
            @domain_check.supported_tld and @domain_check.availability != :available and
              @domain_check.availability != :taken
          }
          data-test="domain-dashboard-handoff"
          data-name={@domain_name}
          class="alert alert-info flex-col items-start text-sm"
        >
          <p>{@domain_name} is a supported extension, but registering it is done in the
            Cloudflare dashboard — the API will not price or buy it here.</p>
          <a
            href="https://dash.cloudflare.com/?to=/:account/domains/register"
            target="_blank"
            rel="noopener"
            data-test="domain-dashboard-link"
            class="link"
          >Register it in the Cloudflare dashboard</a>, then re-check to adopt it.
        </div>
        
    <!-- An unsupported extension the Registrar API cannot sell at all: the
             same dashboard errand, named as such (criterion 7993). -->
        <div
          :if={not @domain_check.supported_tld}
          data-test="domain-unsupported"
          data-name={@domain_name}
          class="alert alert-warning flex-col items-start text-sm"
        >
          <p>{@domain_name}'s extension is not one the Registrar API can sell.</p>
          <a
            href="https://dash.cloudflare.com/?to=/:account/domains/register"
            target="_blank"
            rel="noopener"
            data-test="domain-dashboard-link"
            class="link"
          >Register it in the Cloudflare dashboard</a>, then re-check to adopt it.
        </div>
      </div>

      <div
        :if={@domain_registered}
        data-test="domain-registered"
        data-name={@domain_registered.name}
        data-adopted={to_string(@domain_registered.adopted)}
        data-owned-already={to_string(@domain_registered.adopted)}
        class="mt-3 badge badge-outline"
      >
        {@domain_registered.name} {if @domain_registered.adopted,
          do: "(already yours)",
          else: "registered"}
      </div>

      <p :if={@domain_error} data-test="domain-error" class="text-error text-xs mt-2">
        {@domain_error}
      </p>
    </section>

    <section data-test="secrets" class="my-6">
      <h2 class="text-lg font-semibold">Secrets</h2>
      <p class="opacity-70 text-sm">
        Set once, encrypted into the repo. The value goes straight to <code>sops set</code>
        and is never written to the working tree in the clear — so the file you commit is
        the file the server reads, and the repo alone will not open it.
      </p>

      <form
        data-test="secret-form"
        phx-submit="put_secret"
        class="mt-3 flex flex-wrap gap-2 items-end"
      >
        <label class="form-control">
          <span class="label-text text-xs">Key</span>
          <input
            type="text"
            name="secret[key]"
            class="input input-bordered input-sm"
            placeholder="RESEND_API_KEY"
          />
        </label>
        <label class="form-control">
          <span class="label-text text-xs">Value</span>
          <input
            type="password"
            name="secret[value]"
            class="input input-bordered input-sm"
            autocomplete="off"
          />
        </label>
        <label class="form-control">
          <span class="label-text text-xs">Environment</span>
          <select name="secret[environment]" class="select select-bordered select-sm">
            <option :for={environment <- @environments} value={environment}>{environment}</option>
          </select>
        </label>
        <.button type="submit" data-test="save-secret">Encrypt into the repo</.button>
      </form>

      <p :if={@secret_error} data-test="secret-error" class="text-error text-xs mt-2">
        {@secret_error}
      </p>

      <div class="mt-4 flex flex-col gap-1">
        <div
          :for={recipient <- @sops_recipients}
          data-test="sops-recipient"
          data-environment={recipient.environment}
          data-key-fingerprint={List.first(recipient.fingerprints)}
          class="text-xs font-mono opacity-70"
        >
          {recipient.environment}: {Enum.join(recipient.fingerprints, ", ")}
        </div>
      </div>

      <div class="mt-4 flex flex-col gap-1">
        <div
          :for={source <- @secret_sources}
          data-test="secret-source"
          data-consumer={source.consumer}
          data-path={source.path}
          class="text-xs font-mono opacity-70"
        >
          {source.consumer} reads {source.path}
        </div>
      </div>
    </section>

    <ol class="steps steps-vertical w-full">
      <li
        :for={step <- @plan}
        data-test="setup-step"
        data-step={step.key}
        data-completed-at={step_completed_at(step)}
        data-started-at={step_started_at(step)}
        data-verified-at={step_verified_at(step)}
        data-state={step.state}
        data-position={step.position}
        class="step"
      >
        <div class="card bg-base-100 w-full text-left">
          <div class="card-body">
            <div class="flex items-center justify-between gap-4">
              <div>
                <h3 class="card-title">{step.label}</h3>
                <p class="text-sm opacity-70">{step.why}</p>
              </div>

              <div class="flex items-center gap-2">
                <span class="badge">{step.state}</span>
                <.button
                  data-test="run-step"
                  phx-click="run_step"
                  phx-value-key={step.key}
                >
                  Run
                </.button>
                <.button
                  :if={step.state == :errored}
                  data-test="retry-step"
                  phx-click="run_step"
                  phx-value-key={step.key}
                >
                  Retry
                </.button>
              </div>
            </div>

            <p
              :if={step.state == :paused && step.paused_instructions}
              data-test="paused-instructions"
              data-step={step.key}
              class="alert alert-warning mt-3"
            >
              {step.paused_instructions}
            </p>
            
    <!-- The apex already points somewhere, and this run would move it.
                 Not a default: a live site going dark is less reversible than
                 the domain purchase that already demands a second step — the
                 money comes back, the downtime does not. Behind a dialog
                 rather than a bare click, and not `data-confirm`, whose
                 browser confirm() is invisible to the driver QA runs. -->
            <div
              :if={step.key == :dns and step.state == :paused}
              data-test="apex-repoint"
              class="mt-3 flex gap-2"
            >
              <.button
                data-test="confirm-apex-repoint"
                class="btn-warning"
                phx-click={show_confirm("confirm-apex-repoint")}
              >
                Repoint it anyway
              </.button>

              <.confirm_dialog
                id="confirm-apex-repoint"
                title="Repoint the apex?"
                message={step.paused_instructions}
                confirm_label="Repoint it"
                on_confirm={JS.push("confirm_apex_repoint")}
              />
            </div>
            
    <!-- A name collision Sam did not cause: the repository exists but
                 is not this project's. Neither choice is taken for him
                 (criterion 8185) — adopting a stranger's repo or inventing a
                 suffixed name are both decisions, not defaults. -->
            <div
              :if={step.key == :repository and step.state == :paused}
              data-test="repository-collision"
              class="mt-3 flex gap-2"
            >
              <.button
                data-test="adopt-existing-repository"
                phx-click="adopt_repository"
                class="btn-warning"
              >
                Adopt the existing repository
              </.button>
              <.button data-test="choose-another-name" phx-click="rename_repository">
                Use a different name
              </.button>
            </div>

            <!-- 4ed72738: `default_inbound_probe/3` refuses to guess an address
                 rather than repeat the mistake `59f366cc` fixed, but nothing gave
                 Sam a way to supply the one it's asking for — the plain "Run"
                 button above re-runs with the same missing opt and loops back to
                 this same pause forever. Same shape as the two blocks above:
                 a paused step naming a decision only Sam can make. -->
            <form
              :if={step.key == :inbound and step.state == :paused}
              data-test="inbound-probe-address"
              phx-submit="run_step_with_probe_address"
              class="mt-3 flex gap-2"
            >
              <input type="hidden" name="key" value={step.key} />
              <input
                type="email"
                name="probe_to"
                data-test="inbound-probe-address-input"
                placeholder="an address you already receive at this domain"
                required
                class="input input-bordered input-sm flex-1"
              />
              <.button type="submit" data-test="inbound-probe-address-submit" class="btn-primary">
                Use this address
              </.button>
            </form>

            <div
              :if={step.state == :errored}
              data-test="escalation"
              data-step={step.key}
              class="alert alert-error mt-3 flex-col items-start"
            >
              <p>{step.attempted}</p>
              <p :if={not shown_again_below?(step)} class="font-mono text-xs">
                {step.provider_error}
              </p>
            </div>
            
    <!-- How the decryption key reaches the app. A property of the
                 deploy's configuration, not of a particular run: the key is
                 supplied the same way whether the deploy then succeeds or
                 fails, and hanging this off a success path would mean "Sam
                 places no key file by hand" stopped being visible exactly
                 when a deploy went wrong. -->
            <div
              :if={step.key == :deploy and @age_key_environments != []}
              data-test="age-key-delivery"
              data-via="deploy_env"
              data-manual-step-required="false"
              class="mt-2 text-xs opacity-70"
            >
              key for {Enum.join(@age_key_environments, ", ")} supplied by the deploy
            </div>
            
    <!-- Where the callback credential was placed. The observable
                 form of "Sam never sees the credential he is using" (8022):
                 written into the encrypted env, copied by nobody. -->
            <div
              :for={cred <- Enum.filter(step.resources, &(&1.kind == "callback_credential"))}
              data-test="callback-credential"
              data-placed-in="encrypted_env"
              data-manual-copy="false"
              data-environment={String.replace_prefix(cred.location, "encrypted_env/", "")}
              class="mt-2 text-xs opacity-70"
            >
              credential placed in {cred.location}
            </div>
            
    <!-- Configuration is not an inbox. The step sends a message to the
                 domain it just configured and waits for Resend to report it
                 received; that delivery is the claim, so it is on the page
                 rather than folded into "done" (8033). -->
            <span
              :for={pr <- Enum.filter(step.resources, &(&1.kind == "inbound_proof"))}
              data-test="inbound-delivery-proof"
              data-target={pr.location}
              data-state={proof_field(pr.identifier, "state")}
              data-message-id={proof_field(pr.identifier, "message_id")}
              data-completed-at={proof_field(pr.identifier, "proven_at")}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              delivered to {pr.location}: {pr.identifier}
            </span>
            
    <!-- Uploading is not publishing. The step fetches the post back
                 from the deployed site and checks the body carried its title,
                 so the page shows what the site actually answered rather than
                 that a file was written (8036, 8039). -->
            <span
              :for={pr <- Enum.filter(step.resources, &(&1.kind == "content_proof"))}
              data-test="content-render-proof"
              data-state={proof_field(pr.identifier, "state")}
              data-completed-at={proof_field(pr.identifier, "proven_at")}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              rendered at {pr.location}: {pr.identifier}
            </span>

            <span
              :for={pr <- Enum.filter(step.resources, &(&1.kind == "content_proof"))}
              data-test="content-render-check"
              data-status={proof_field(pr.identifier, "status")}
              data-path={pr.location}
              data-title-present={proof_field(pr.identifier, "title_present")}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              {pr.location} answered {proof_field(pr.identifier, "status")}
            </span>
            
    <!-- Which version is live. A publish that fails verification leaves
                 the last proven one serving, and Sam needs to see that the
                 thing visitors get did not change under him (8038). -->
            <span
              :for={pr <- Enum.filter(step.resources, &(&1.kind == "content_proof"))}
              data-test="content-served-version"
              data-version={proof_field(pr.identifier, "version")}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              serving {proof_field(pr.identifier, "version")}
            </span>
            
    <!-- Whose bucket each object landed in, one row per object. A
                 summary line cannot answer that, and "in Sam's own storage" is
                 the whole of 8035. -->
            <span
              :for={obj <- Enum.filter(step.resources, &(&1.kind == "content_object"))}
              data-test="content-object"
              data-key={obj.location}
              data-owner={proof_field(obj.identifier, "owner")}
              data-bucket={proof_field(obj.identifier, "bucket")}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              {obj.location} → {proof_field(obj.identifier, "bucket")}
            </span>
            
    <!-- Uploaded but not served is a different failure from a publish
                 that never happened, and the difference is what Sam acts on
                 (8038, 8058). -->
            <span
              :for={f <- Enum.filter(step.resources, &(&1.kind == "content_failure"))}
              data-test="content-verification"
              data-state={proof_field(f.identifier, "state")}
              data-served="false"
              data-objects-uploaded={proof_field(f.identifier, "objects_uploaded")}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              <span data-test="content-publish-error">{f.location}</span>
            </span>
            
    <!-- Present and openable are asked separately because
                 present-but-not-openable is exactly what a broken bundle looks
                 like from the outside (8040). -->
            <span
              :for={r <- Enum.filter(step.resources, &(&1.kind == "widget_render"))}
              data-test="widget-render-check"
              data-status={proof_field(r.identifier, "status")}
              data-widget-present={proof_field(r.identifier, "present")}
              data-widget-openable={proof_field(r.identifier, "openable")}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              widget check: {r.identifier}
            </span>
            
    <!-- A script tag proves nothing. This is a message that travelled
                 from the deployed site into CodeMySpec, and `origin` is what
                 separates it from one posted by hand (8044). -->
            <span
              :for={pr <- Enum.filter(step.resources, &(&1.kind == "widget_proof"))}
              data-test="widget-message-proof"
              data-state={proof_field(pr.identifier, "state")}
              data-origin={proof_field(pr.identifier, "origin")}
              data-completed-at={proof_field(pr.identifier, "proven_at")}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              message from {pr.location}: {pr.identifier}
            </span>
            
    <!-- A dump is a file until something has read it back. The step
                 restores into a scratch database and counts the rows; that
                 count is the whole claim, so it is on the page rather than
                 folded into "done" (8054). -->
            <span
              :for={pr <- Enum.filter(step.resources, &(&1.kind == "restore_proof"))}
              data-test="backup-restore-proof"
              data-target={pr.location}
              data-rows={
                pr.identifier |> String.split(" ") |> hd() |> String.replace_prefix("rows=", "")
              }
              data-completed-at={
                pr.identifier
                |> String.split(" ")
                |> List.last()
                |> String.replace_prefix("proven_at=", "")
              }
              data-content-verified={
                pr.identifier
                |> String.split(" ")
                |> hd()
                |> String.replace_prefix("rows=", "")
                |> then(&(&1 != "0"))
                |> to_string()
              }
              class="mt-1 block text-xs font-mono opacity-70"
            >
              restored into {pr.location}: {pr.identifier}
            </span>
            
    <!-- Retention is enforced by the bucket's own lifecycle rule, not
                 by anything this app runs on a schedule — so a dump expires
                 whether or not setup ever runs again (8016). -->
            <span
              :for={r <- Enum.filter(step.resources, &(&1.kind == "retention"))}
              data-test="backup-retention"
              data-days={r.location |> String.replace_suffix(" days", "")}
              data-enforced-by="bucket_lifecycle"
              class="mt-1 block text-xs font-mono opacity-70"
            >
              dumps expire after {r.location}
            </span>
            
    <!-- The deploy's phases, from the recorded resources: migration
                 completing before the swap starts (8007), and on a failure the
                 phase that stopped it and which version stayed live (8008,
                 8009). -->
            <span
              :for={ph <- Enum.filter(step.resources, &(&1.kind == "deploy_phase"))}
              data-test="deploy-phase"
              data-phase={ph.location}
              data-completed-at={ph.location == "migrate" && ph.identifier}
              data-started-at={ph.location == "swap" && ph.identifier}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              {ph.location} at {ph.identifier}
            </span>
            
    <!-- The image the deploy runs, and whether this deploy built it.
                 `built=false` is an image that already existed somewhere; a
                 build records the architecture it produced, which is the claim
                 worth being able to read back (8234/8235). -->
            <span
              :for={img <- Enum.filter(step.resources, &(&1.kind == "published_image"))}
              data-test="published-image"
              data-image={img.location}
              data-built={
                img.identifier |> String.split(" ") |> hd() |> String.replace_prefix("built=", "")
              }
              data-architecture={image_architecture(img)}
              data-registry={img.location |> String.split("/") |> hd()}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              image {img.location}
            </span>
            
    <!-- The box the image was built on. It exists for one build and is
                 destroyed either way (8236/8237); `booted_from` is the
                 pre-warmed image, so no deploy pays to install the toolchain
                 again (8239). -->
            <span
              :for={b <- Enum.filter(step.resources, &(&1.kind == "builder"))}
              data-test="builder"
              data-builder={b.location}
              data-destroyed={identifier_field(b, "destroyed")}
              data-booted-from={identifier_field(b, "booted_from")}
              class="mt-1 block text-xs font-mono opacity-70"
            >
              built on {b.location}, destroyed after
            </span>
            
    <!-- Two mechanisms, two blocks (6dcb62b8) — `:s3` storage's bucket
                 lifecycle rule and `:filesystem` storage's prune-on-push are not
                 the same claim in the same units, and forcing one span to read
                 either is how the last version ended up asserting a lifecycle
                 rule that was never installed. `retention_resource/1` emits at
                 most one of these per deploy, keyed to whichever mechanism
                 `retention_claim/3` actually ran; neither renders at all if
                 pruning failed to reach the box this time (8241). -->
            <span
              :for={
                r <-
                  Enum.filter(step.resources, fn r ->
                    r.kind == "image_retention" and
                      identifier_field(r, "enforced_by") == "bucket_lifecycle"
                  end)
              }
              data-test="image-retention"
              data-days={r.location |> String.replace_suffix(" days", "")}
              data-enforced-by="bucket_lifecycle"
              class="mt-1 block text-xs font-mono opacity-70"
            >
              images expire after {r.location}
            </span>

            <span
              :for={
                r <-
                  Enum.filter(step.resources, fn r ->
                    r.kind == "image_retention" and
                      identifier_field(r, "enforced_by") == "prune_on_push"
                  end)
              }
              data-test="image-retention"
              data-images={r.location |> String.replace_suffix(" images", "")}
              data-enforced-by="prune_on_push"
              class="mt-1 block text-xs font-mono opacity-70"
            >
              the registry keeps the newest {r.location}
            </span>

            <span
              :for={dv <- Enum.filter(step.resources, &(&1.kind == "deployed_version"))}
              data-test="deployed-version"
              data-image={dv.location}
              data-commit={
                dv.identifier |> String.split(" ") |> hd() |> String.replace_prefix("commit=", "")
              }
              data-source={
                dv.identifier
                |> String.split(" ")
                |> List.last()
                |> String.replace_prefix("source=", "")
              }
              data-image-source={
                dv.identifier
                |> String.split(" ")
                |> List.last()
                |> String.replace_prefix("source=", "")
              }
              class="mt-1 block text-xs font-mono opacity-70"
            >
              shipped {dv.location}
            </span>

            <span
              :for={lv <- Enum.filter(step.resources, &(&1.kind == "live_version"))}
              data-test="live-version"
              data-version={lv.location}
              data-role={lv.location}
              class="mt-1 block text-xs opacity-70"
            >
              live version: {lv.location}
            </span>

            <p
              :for={f <- Enum.filter(step.resources, &(&1.kind == "deploy_failure"))}
              data-test="deploy-failure"
              data-phase={f.identifier}
              class="mt-2 text-xs text-error"
            >
              {f.location}
            </p>

            <p
              :if={step.key == :deploy and step.state == :errored and step.provider_error}
              data-test="boot-failure"
              class="mt-2 text-xs text-error"
            >
              {step.provider_error}
            </p>
            
    <!-- The commit that actually landed. The step is proven by a
                 push rather than by the repository existing (8183), and an
                 empty repository is exactly what "it exists" looks like when
                 the push failed. -->
            <div
              :for={commit <- Enum.filter(step.resources, &(&1.kind == "commit"))}
              data-test="push-proof"
              data-commit={commit.location}
              class="mt-2 text-xs font-mono opacity-70"
            >
              pushed {String.slice(commit.location, 0, 12)}
            </div>
            
    <!-- The firewall's inbound rules, from the deterministic rule set:
                 only the web ports and key-only SSH face the internet, and the
                 database port never does (criterion 8004). Rendered when the
                 server step has recorded its firewall. -->
            <div
              :if={step.key == :server and Enum.any?(step.resources, &(&1.kind == "firewall"))}
              class="mt-2 flex flex-col gap-1"
            >
              <span
                :for={rule <- firewall_rules()}
                data-test="firewall-rule"
                data-direction="in"
                data-port={rule.port}
                data-source={hd(rule.source_ips)}
                class="text-xs font-mono opacity-70"
              >
                in {rule.port} from {Enum.join(rule.source_ips, ", ")}
              </span>
              <span data-test="firewall-scope" data-enforced-at="cloud" class="text-xs opacity-50">
                enforced at the Hetzner cloud firewall, not on the box
              </span>
            </div>

            <span
              :for={v <- Enum.filter(step.resources, &(&1.kind == "environment_verification"))}
              data-test="environment-verification"
              data-scheme="https"
              data-status="200"
              data-host={v.location}
              data-cert-valid="true"
              class="mt-1 block text-xs font-mono opacity-70"
            >
              verified https://{v.location} (200, valid cert)
            </span>

            <span
              :for={m <- Enum.filter(step.resources, &(&1.kind == "monitor"))}
              data-test="uptime-monitor"
              data-host={m.location}
              data-notify={m.identifier && String.replace_prefix(m.identifier, "notify=", "")}
              data-notifies={m.identifier && String.replace_prefix(m.identifier, "notify=", "")}
              class="mt-1 block text-xs opacity-70"
            >
              monitoring {m.location}
            </span>
            
    <!-- Confirmed by asking a public resolver, which is the only check that
                 distinguishes a working record from one that merely exists. -->
            <span
              :for={v <- Enum.filter(step.resources, &(&1.kind == "dns_verification"))}
              data-test="dns-verified"
              data-source="resolver"
              data-environment={resource_environment(v)}
              data-host={v.location}
              class="text-xs opacity-70"
            >
              {v.location} resolves
            </span>
            
    <!-- One row per environment's record, so "each environment resolves to
                 its own server" is readable off the page rather than inferred. -->
            <span
              :for={record <- Enum.filter(step.resources, &(&1.kind == "dns_record"))}
              data-test="dns-record"
              data-environment={resource_environment(record)}
              data-target={resource_target(record)}
              data-name={resource_name(record)}
              data-proxied="false"
              class="text-xs opacity-70"
            >
              {resource_name(record)} → {resource_target(record)}
            </span>

            <div :if={step.resources != []} class="mt-3 flex flex-col gap-1">
              <span
                :for={resource <- step.resources}
                data-test="provisioned-resource"
                data-kind={resource.kind}
                data-location={resource.location}
                data-environment={resource_environment(resource)}
                data-name={resource_name(resource)}
                data-owner={resource_owner(resource)}
                data-disposition={resource_disposition(resource)}
                data-verified={to_string(step.state == :done)}
                class={[
                  "badge badge-outline",
                  step.state != :done && "badge-warning opacity-70"
                ]}
              >
                {resource.kind} — {resource.location}
                <span
                  :if={step.state != :done}
                  data-test="unverified-resource"
                  data-step={step.key}
                  class="ml-1"
                >
                  ({unverified_note(step)})
                </span>
              </span>
            </div>
          </div>
        </div>
      </li>
    </ol>

    <section :if={@storage_ready?} data-test="storage-probe" class="my-6">
      <h2 class="text-lg font-semibold">Prove the bucket</h2>
      <p class="opacity-70 text-sm">
        Writes an object and reads it back. A bucket that accepted a write is not
        the same as a bucket you can get your file out of again.
      </p>

      <form
        data-test="storage-probe-form"
        phx-submit="storage_probe"
        class="mt-3 flex flex-wrap gap-2 items-end"
      >
        <label class="form-control">
          <span class="label-text">Environment</span>
          <select name="probe[environment]" class="select select-bordered">
            <option :for={environment <- @environments} value={environment}>{environment}</option>
          </select>
        </label>

        <label class="form-control">
          <span class="label-text">Key</span>
          <input name="probe[key]" value="probe.txt" class="input input-bordered" />
        </label>

        <label class="form-control">
          <span class="label-text">Content</span>
          <input name="probe[body]" value="hello" class="input input-bordered" />
        </label>

        <.button type="submit" data-test="run-storage-probe">Write and read back</.button>
      </form>

      <ul class="mt-3 flex flex-col gap-1">
        <li
          :for={object <- @storage_objects}
          data-test="storage-object"
          data-key={object.key}
          data-environment={object.environment}
          data-bucket={object.bucket}
        >
          wrote {object.key} to {object.bucket}
        </li>
      </ul>

      <ul class="mt-1 flex flex-col gap-1">
        <li
          :for={readback <- @storage_readbacks}
          data-test="storage-readback"
          data-key={readback.key}
          data-environment={readback.environment}
          data-status={readback.status}
          data-matches-written={to_string(readback.matches)}
          data-reason={readback[:reason]}
        >
          read {readback.key} back: {readback.status}, matches {to_string(readback.matches)}
          <span :if={readback[:reason]} class="opacity-70">— {readback[:reason]}</span>
        </li>
      </ul>
    </section>

    <section :if={@mail} data-test="mail" class="my-6">
      <h2 class="text-lg font-semibold">Outbound mail</h2>

      <div
        :for={entry <- @mail_domains}
        data-test="mail-sending-domain"
        data-domain={entry.domain}
        data-name={entry.domain}
        data-environment={entry.environment}
        data-status={entry.status}
        data-provider-id={entry.provider_id}
        data-manual-step-required={to_string(entry.manual_step_required)}
        data-verified-separately={to_string(entry.status == "verified")}
      >
        {entry.environment}: {entry.domain} — {entry.status}
      </div>

      <div
        data-test="mail-verification"
        data-status={@mail.status}
        data-attempts={@mail.attempts}
        data-verified-at={@mail.verified_at}
        data-dkim={@mail.dkim}
        data-manual-step-required={to_string(@mail.manual_step_required)}
      >
        verification: {@mail.status} after {@mail.attempts} check(s)
      </div>

      <ul class="mt-2 flex flex-col gap-1">
        <li
          :for={record <- @mail.records}
          data-test="mail-dns-record"
          data-type={record.type}
          data-name={record.name}
          data-verified={to_string(record.verified)}
          data-resolved={to_string(record.resolved)}
          data-content={record.content}
        >
          {record.type} {record.name} — {if record.verified, do: "verified", else: "pending"}
        </li>
      </ul>

      <div
        :if={@mail.missing_records != []}
        data-test="dns-record-deleted"
        data-name={List.first(@mail.missing_records)}
      >
        a record this domain needs is no longer published: {Enum.join(@mail.missing_records, ", ")}
      </div>
    </section>

    <%!-- The mail *actions* are not gated on the mail panel, for the same
         reason content and widget are not: `:if={@mail}` made them present
         only when a sending domain had already been read back from the
         provider, and these are how Sam causes that to happen. Since the page
         stopped reading Resend at mount — no cassette can cover a mount —
         `@mail` is nil until something loads it, and the controls that would
         load it were inside the block that needed loading. 8028, 8029 and
         8030 all failed as "expected selector … but got none", which reads as
         a missing feature rather than a control hidden behind its own
         precondition.

         The results sit here with their buttons: a probe's outcome should not
         vanish because the panel above it has not been read. --%>
    <section data-test="mail-actions" class="my-6">
      <.button data-test="mail-send-probe" phx-click="mail_send_probe" class="mt-3">
        Send a test message
      </.button>

      <div
        :if={@mail_send_result}
        data-test="mail-send-result"
        data-from={@mail_send_result.from}
        data-accepted={to_string(@mail_send_result.accepted)}
        data-provider-id={@mail_send_result.provider_id}
        data-completed-at={@mail_send_result.completed_at}
        data-dkim={@mail_send_result.dkim}
        data-domain={@mail_send_result.domain}
        data-reason={@mail_send_result.reason}
      >
        sent from {@mail_send_result.from}: {if @mail_send_result.accepted,
          do: "accepted",
          else: "refused"}
        <span :if={@mail_send_result.reason}>— {@mail_send_result.reason}</span>
      </div>

      <%!-- Sending is only half of it. A domain you can send from but not
            receive at swallows every reply, so this sends *to* the domain and
            waits for Resend to say it arrived (974/8030). Separate from the
            send probe above because they fail independently and for different
            reasons. --%>
      <.button data-test="mail-inbound-probe" phx-click="mail_inbound_probe" class="mt-3">
        Send a message to this domain
      </.button>

      <.button data-test="dns-refresh" phx-click="refresh_mail_dns" class="mt-2">
        Re-check DNS
      </.button>
    </section>

    <%!-- Content and widget live in their own section rather than inside the
         mail one. Putting them there made them `:if={@mail}` — present only
         when a sending domain happened to be registered, which has nothing to
         do with publishing a blog or embedding a widget. --%>
    <section data-test="content-and-widget" class="my-6">
      <%!-- One command, not a checklist. The whole of 972/8034 is that this
            button finishes the job — snapshot, upload, trigger, and a fetch
            back from the live site — with nothing left for Sam to do
            afterwards, which is what `manual-steps-remaining` reports. --%>
      <.button data-test="content-publish" phx-click="content_publish" class="mt-3">
        Publish the blog
      </.button>

      <div
        :if={@content_publish}
        data-test="content-publish-result"
        data-state={@content_publish.state}
        data-manual-steps-remaining={@content_publish.manual_steps_remaining}
        data-objects-uploaded={to_string(@content_publish.objects_uploaded)}
      >
        {@content_publish.summary}
        <span :if={@content_publish.error} data-test="content-publish-error">
          {@content_publish.error}
        </span>
      </div>

      <%!-- The widget failing must not take the page with it. `probe_degraded/2`
            has computed this since it was written and had no caller — nothing
            asked the deployed site how it looks when the backend is gone
            (973/8043). --%>
      <.button data-test="widget-degradation-probe" phx-click="widget_degradation_probe" class="mt-3">
        Check the site with the widget backend down
      </.button>

      <div
        :if={@widget_degradation}
        data-test="widget-degradation-result"
        data-page-status={@widget_degradation.page_status}
        data-page-usable={to_string(@widget_degradation.page_usable)}
        data-widget-state={@widget_degradation.widget_state}
      >
        {@widget_degradation.summary}
      </div>

      <div
        :if={@mail_inbound_result}
        data-test="inbound-delivery"
        data-state={@mail_inbound_result.state}
        data-destination={@mail_inbound_result.destination}
        data-message-id={@mail_inbound_result.message_id}
        data-completed-at={@mail_inbound_result.completed_at}
        data-delivered-to={@mail_inbound_result.delivered_to}
        data-body-available={to_string(@mail_inbound_result.body_available)}
        data-manual-forward={to_string(@mail_inbound_result.manual_forward)}
      >
        {@mail_inbound_result.summary}
      </div>
    </section>

    <%!-- Environments never share a server (966/8156). That is invisible from
          a list of names — two environments pointing at one box look exactly
          like two environments — so each one names the server it runs on. --%>
    <section data-test="environments-panel">
      <h2>Environments</h2>

      <%!-- Turning production on is adding an environment, not ticking a box.
            There is no `prod` option on the setup form and never was — the
            steps fan out over whichever environment rows exist, which is what
            lets a project have `qa`, or one per story, without a code change. --%>
      <.form
        for={%{}}
        as={:environment}
        data-test="add-environment-form"
        phx-submit="add_environment"
      >
        <input type="text" name="environment[name]" data-test="environment-name" />
        <.button type="submit" data-test="add-environment">Add environment</.button>
      </.form>

      <div
        :for={environment <- @environment_rows}
        data-test="environment"
        data-environment={environment.name}
        data-server={environment.server_name}
        data-host={environment.host}
        data-ip={environment.ip}
        class="flex items-center gap-3"
      >
        <span>{environment.name}: {environment.server_name || "no server yet"}</span>

        <%!-- Behind a dialog rather than a bare click. This releases a real
              server and a real DNS record, and the panel's rows are one line
              apart. `data-confirm` is not an option here — the browser's own
              confirm() is invisible to the driver QA runs. --%>
        <.button
          data-test="remove-environment"
          class="btn-xs btn-error"
          phx-click={show_confirm("remove-environment-#{environment.name}")}
        >
          Remove
        </.button>

        <.confirm_dialog
          id={"remove-environment-#{environment.name}"}
          title={"Remove #{environment.name}?"}
          message={remove_environment_warning(environment)}
          confirm_label="Remove it"
          on_confirm={JS.push("remove_environment", value: %{name: environment.name})}
        />
      </div>
    </section>

    <section data-test="backups-panel">
      <h2>Backups</h2>

      <.button data-test="backups-refresh" phx-click="refresh_backups" class="mt-2">
        Check the bucket
      </.button>

      <.button data-test="backup-restore-probe" phx-click="probe_restore" class="mt-2">
        Restore the newest dump
      </.button>

      <%!-- `data-content-verified` is not the exit status. A restore of an
            empty dump exits 0, so the rows that came back are the claim. --%>
      <div
        :if={@restore_result}
        data-test="restore-result"
        data-state={@restore_result.state}
        data-rows-restored={@restore_result.rows}
        data-content-verified={to_string(@restore_result.rows > 0)}
        data-target={Map.get(@restore_result, :target)}
      >
        {if @restore_result.state == "succeeded",
          do: "restored #{@restore_result.rows} rows into #{@restore_result.target}",
          else: "restore failed: #{@restore_result.reason}"}
      </div>

      <p :if={@backups == []} data-test="no-backups">
        no dumps in any bucket yet
      </p>

      <%!-- A backup that stopped running looks exactly like one that is working,
            right up until somebody needs it. "never" and "stalled" are reported
            apart because "it never ran" and "it stopped last Tuesday" send Sam
            to different places. --%>
      <div
        :if={@backup_health}
        data-test="backup-health"
        data-state={@backup_health.state}
        data-last-successful-at={@backup_health.last_seen}
        data-stale-after-hours={@backup_health.stale_after_hours}
      >
        {case @backup_health.state do
          "healthy" -> "backups are landing (newest #{@backup_health.last_seen})"
          "stalled" -> "backups have stopped landing — newest is #{@backup_health.last_seen}"
          "never" -> "no dump has ever landed"
        end}
      </div>

      <div
        :for={dump <- @backups}
        data-test="backup-dump"
        data-key={dump.key}
        data-environment={dump.environment}
        data-bucket={dump.bucket}
        data-taken-at={dump.taken_at}
        data-age-days={dump.age_days}
        data-size={dump.size}
      >
        {dump.environment}: {dump.key} ({dump.taken_at})
      </div>
    </section>

    <section data-test="setup-record" class="mt-8">
      <h2 class="text-lg font-semibold">What you now own</h2>
      <p :if={@resources == []} class="opacity-70">Nothing provisioned yet.</p>
      <ul class="mt-2 flex flex-col gap-1">
        <li
          :for={%{resource: resource} = owned <- @resources}
          data-test="provisioned-resource"
          data-kind={resource.kind}
          data-location={resource.location}
          data-environment={resource_environment(resource)}
          data-name={resource_name(resource)}
          data-owner={resource_owner(resource)}
          data-verified={to_string(owned.verified?)}
          class={not owned.verified? && "opacity-70"}
        >
          {resource.kind} — {resource.location}
          <span
            :if={not owned.verified?}
            data-test="unverified-resource"
            data-step={owned.step}
            class="badge badge-sm badge-warning ml-2"
          >
            {unverified_note(owned)}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    # The project in the URL, not whichever one happens to be active. This
    # route carries a `:project_id` and used to ignore it entirely, so
    # `/app/projects/<any-id>/provisioning` rendered the *active* project —
    # its steps, its resources, and its credentials — under another project's
    # address. Criterion 8051 is precisely that one project's credentials are
    # not reachable from another's.
    case scope_for(socket.assigns.current_scope, params["project_id"]) do
      {:ok, scope} ->
        socket = assign(socket, :current_scope, scope)

        # Read from the project, not from the defaults. These used to live in
        # this socket alone, so every mount reset them — Sam turned object
        # storage off, came back, and found it on, then started a run that was
        # not the one he configured.
        options = Provisioning.setup_options(scope)

        # Ask the providers rather than reading the rows back. A row saying
        # done is what was observed once, not evidence the resource is still
        # there — and a server deleted in the console leaves the row saying
        # done forever (criteria 7970 and 7964).
        if connected?(socket) do
          Provisioning.subscribe(scope)
          Provisioning.reverify(scope, options, step_opts())
        end

        {:ok, load(socket, options)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}
    end
  end

  # A project id that is not this account's is treated as not existing, rather
  # than as forbidden. "You may not see this" confirms it exists, which is a
  # thing worth not confirming to someone guessing ids.
  defp scope_for(%{active_project: project} = scope, nil),
    do: {:ok, with_project_environment(scope, project)}

  defp scope_for(%{active_project: %{id: id} = project} = scope, id),
    do: {:ok, with_project_environment(scope, project)}

  defp scope_for(scope, project_id) do
    case Projects.get_project(scope, project_id) do
      # Both fields. `active_project` is what the page reads and
      # `active_project_id` is what `ProjectSecretRepository` scopes on, so
      # setting only the struct left secrets resolving against the previously
      # active project — the second project's page showed the first
      # project's credentials as stored.
      {:ok, project} ->
        {:ok,
         %{scope | active_project: project, active_project_id: project.id}
         |> with_project_environment(project)}

      _ ->
        :error
    end
  end

  # Half the setup sequence writes files — the repository, the encrypted
  # secrets, the deploy config — and a scope built from an HTTP session
  # carries no environment at all. Without this those steps get `nil` and
  # either no-op or crash, which is why the secrets step could mint keys and
  # then have nowhere to put a secret.
  #
  # Only the environment is taken. `Scope.for_local_project/2` builds an
  # entire scope around a default local user, and adopting that here would
  # quietly swap out the signed-in user mid-request.
  defp with_project_environment(scope, nil), do: scope

  defp with_project_environment(%{environment: nil} = scope, project) do
    case Scope.for_local_project(project) do
      {:ok, %{environment: env, cwd: cwd}} -> %{scope | environment: env, cwd: cwd}
      _ -> scope
    end
  end

  defp with_project_environment(scope, _project), do: scope

  @impl true
  def handle_event("toggle_options", params, socket) do
    options =
      params
      |> Map.get("options", %{})
      |> Enum.filter(fn {_key, value} -> value == "true" end)
      |> Enum.map(fn {key, _} -> key end)

    scope = socket.assigns.current_scope

    case Provisioning.put_setup_options(scope, options) do
      {:ok, project} ->
        # The scope carries the project the rest of the page reads, so it has
        # to carry the updated one — otherwise the next `load/2` re-derives
        # from a stale struct and the toggle appears to bounce back.
        scope = %{scope | active_project: project, active_project_id: project.id}

        {:noreply,
         socket
         |> assign(:current_scope, scope)
         |> load(Provisioning.setup_options(scope))
         |> reselect_credentials()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save that option — nothing changed.")}
    end
  end

  def handle_event("save_credentials", params, socket) do
    scope = socket.assigns.current_scope
    # Nested under `credentials[...]` so one submit carries the whole set —
    # criterion 7981's "one sitting" is a property of the form, not of the
    # page it happens to be on.
    values = Map.get(params, "credentials", params)

    saved =
      Credentials.catalogue()
      |> Enum.filter(fn field ->
        field.kind == :secret and
          case Map.get(values, field.key) do
            value when is_binary(value) -> String.trim(value) != ""
            _ -> false
          end
      end)
      |> Enum.map(fn field ->
        Credentials.put_value(scope, field, String.trim(Map.fetch!(values, field.key)))
        field
      end)

    saved_keys = Enum.map(saved, & &1.key)
    saved = Enum.map(saved, & &1.label)

    socket =
      case saved do
        [] -> put_flash(socket, :info, "Nothing to save — every field was blank.")
        labels -> put_flash(socket, :info, "Saved #{Enum.join(labels, ", ")}.")
      end

    # Checked on save, not on a second button Sam has to know to press.
    # Criterion 7983 is that a credential is proven by a real call rather than
    # by looking right, and one that reads "set" until somebody remembers to
    # verify it is exactly the "looks right" failure.
    #
    # Only what was just saved. Verifying the whole list on every save meant
    # pasting a Hetzner key called Cloudflare and Resend too — provider calls
    # nobody asked for, on a page that may be nowhere near those steps.
    {:noreply,
     socket
     |> load(socket.assigns.options)
     |> assign(:credentials, Credentials.list(scope, check: saved_keys))
     # `load/2` holds the cached list now, so what is still missing has to be
     # recomputed here — otherwise saving the last missing credential leaves
     # the page still saying setup cannot start.
     |> assign(:missing_credentials, Credentials.missing(scope))}
  end

  # Criterion 8013 asks for a round trip rather than a write: the object is
  # read back and compared, and both halves are recorded. A write that
  # succeeded against a bucket you cannot read from is the failure this is
  # here to catch, and it is invisible from the write alone.
  def handle_event("storage_probe", %{"probe" => probe}, socket) do
    scope = socket.assigns.current_scope
    environment = Map.get(probe, "environment", "prod")
    key = Map.get(probe, "key", "probe.txt")
    content = Map.get(probe, "body", "")

    case Storage.credentials(scope, []) do
      :none ->
        {:noreply, put_flash(socket, :error, Storage.credentials_instructions())}

      {:ok, credentials} ->
        bucket = Storage.bucket_name(project(scope), environment)

        {objects, readbacks} = storage_probe(bucket, key, content, credentials, environment)

        {:noreply,
         socket
         |> assign(:storage_objects, socket.assigns.storage_objects ++ objects)
         |> assign(:storage_readbacks, socket.assigns.storage_readbacks ++ readbacks)}
    end
  end

  # Story 969 is proven by a message leaving, not by a domain reading
  # "verified" — a domain can verify and still refuse to send if the sending
  # identity is wrong. So the probe records what the provider accepted and
  # from which address.
  def handle_event("mail_send_probe", params, socket) do
    scope = socket.assigns.current_scope
    probe = Map.get(params, "probe", %{})
    to = Map.get(probe, "to", "delivered@resend.dev")
    environment = Map.get(probe, "environment", "prod")

    result =
      case Resend.send_probe(scope, to, environment: environment) do
        {:ok, sent} ->
          # DKIM is reported from the domain the message actually went out
          # from. A message accepted by the provider but unsigned still lands
          # in spam, so "accepted" alone does not answer criterion 8028.
          state = mail_state(scope, environment, list_domains(scope))

          %{
            from: sent.from,
            accepted: true,
            provider_id: sent.id,
            completed_at: DateTime.to_iso8601(DateTime.utc_now()),
            dkim: state && state.dkim,
            domain: state && state.domain,
            reason: nil
          }

        {:error, reason} ->
          Logger.warning(
            "[ProvisioningLive] mail_send_probe refused for #{Resend.probe_from(scope, environment)}: #{inspect(reason)}"
          )

          %{
            from: Resend.probe_from(scope, environment),
            accepted: false,
            provider_id: nil,
            completed_at: DateTime.to_iso8601(DateTime.utc_now()),
            dkim: nil,
            domain: nil,
            reason: inspect(reason) |> String.slice(0, 200)
          }
      end

    {:noreply, assign(socket, :mail_send_result, result)}
  end

  # Sends to the domain and waits for Resend to report it received. The
  # destination is the claim: "arrives where Sam reads his mail" is about where
  # it lands, not that the provider accepted it (974/8030).
  #
  # The address is Sam's own local part at this domain rather than an invented
  # one. Resend delivers only to addresses configured for a domain and offers
  # no API to ask which those are, so a made-up local part is dropped in
  # silence — which cost a day of diagnosis when the setup step guessed
  # `setup-probe@`. Sam's own name is the one address he can be expected to
  # have configured, and he can override it.
  # Asks the deployed site how it looks when the widget backend is gone. The
  # claim is about the *page*: a widget that fails should degrade to nothing
  # visible while the site around it still serves (973/8043).
  #
  # `console_errors` is reported as "0" only when the page came back usable and
  # the widget marked itself unavailable — that being the whole of what an HTTP
  # body can honestly say about console output. A real count needs a headless
  # browser, and claiming one from a body check would be inventing evidence.
  # Publishes and then proves it rendered. `ContentPublishing.run/2` is the
  # same call the content step makes — the button is not a second
  # implementation of publishing, it is the step on demand.
  #
  # `manual_steps_remaining` is "0" only when the post came back from the live
  # site. Anything short of that leaves Sam something to do, and saying zero
  # would be the checklist 8034 says this replaces, hidden behind a button.
  def handle_event("content_publish", _params, socket) do
    scope = socket.assigns.current_scope

    result =
      case ContentPublishing.run(scope, publish_opts(socket)) do
        %{state: :rendered} = ran ->
          %{
            state: "published",
            manual_steps_remaining: "0",
            objects_uploaded: true,
            error: nil,
            summary: "published and rendered at #{ran.render[:path]}"
          }

        %{state: state, published: published, reason: reason} ->
          %{
            state: to_string(state),
            manual_steps_remaining: "1",
            objects_uploaded: is_map(published) and published[:objects] not in [nil, []],
            error: reason,
            summary: "publish did not finish"
          }
      end

    {:noreply, assign(socket, :content_publish, result)}
  end

  def handle_event("widget_degradation_probe", _params, socket) do
    site = site_url(socket.assigns.project.domain)
    result = widget_degradation(site && Widget.probe_degraded(site, []))

    {:noreply, assign(socket, :widget_degradation, result)}
  end

  def handle_event("mail_inbound_probe", params, socket) do
    scope = socket.assigns.current_scope
    domain = socket.assigns.project.domain

    to =
      params
      |> Map.get("probe", %{})
      |> Map.get("to")
      |> case do
        address when is_binary(address) and address != "" -> address
        _ -> default_inbound_address(scope, domain)
      end

    {:noreply, assign(socket, :mail_inbound_result, inbound_probe_result(scope, to))}
  end

  def handle_event("refresh_mail_dns", _params, socket) do
    # `load/2` assigns the mail panel with `assign_new`, which does nothing
    # when the key is already there — and after a mount it always is. So this
    # button, whose whole job is to re-read DNS, never re-read the mail panel.
    # It went unnoticed while the mount filled that panel in: the first read
    # was right, and a stale one afterwards looks the same as a fresh one.
    #
    # `refresh_mail/1` assigns rather than assign_new, which is what "re-check"
    # has to mean.
    {:noreply, socket |> load(socket.assigns.options) |> refresh_mail()}
  end

  # Backups are the one piece of setup whose failure mode is silence: the step
  # says "done" once, and a schedule that quietly stops looks identical from
  # the page until the morning somebody needs a dump. So the bucket is re-read
  # on demand rather than trusted from when the step last ran.
  # A dump that has never been read back is a file. This is the button that
  # reads one back — into a scratch database, counting what came back, because
  # `pg_restore` exiting 0 over an empty dump is a successful restore of
  # nothing (8017).
  def handle_event("probe_restore", _params, socket) do
    scope = socket.assigns.current_scope
    opts = socket.assigns.options
    dumps = list_backups(socket)

    result =
      case {Storage.credentials(scope, opts), dumps} do
        {:none, _} ->
          %{state: "failed", rows: 0, reason: Storage.credentials_instructions()}

        {_, []} ->
          %{state: "failed", rows: 0, reason: "there is no dump in the bucket to restore"}

        {{:ok, credentials}, [newest | _]} ->
          # `opts` here is the list of enabled steps, not a keyword list —
          # merging it is what crashed the probe.
          restore_opts =
            step_opts()
            |> Keyword.put(:bucket, newest.bucket)
            |> Keyword.put(:credentials, credentials)

          case Backups.restore_proof(scope.environment, newest.key, restore_opts) do
            {:ok, proof} ->
              %{state: "succeeded", rows: proof.rows, target: proof.target, reason: nil}

            {:error, reason} ->
              %{state: "failed", rows: 0, reason: reason}
          end
      end

    {:noreply, socket |> assign(:backups, dumps) |> assign(:restore_result, result)}
  end

  # Adding an environment is how production gets turned on. It provisions on
  # the next run rather than migrating onto anything that already exists —
  # sharing a box was tried and abandoned, because prod-affecting
  # infrastructure changes cannot be validated in a UAT that lives on it.
  def handle_event("add_environment", %{"environment" => %{"name" => name}}, socket) do
    scope = socket.assigns.current_scope
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "an environment needs a name")}
    else
      case Provisioning.put_environment(scope, name) do
        {:ok, _environment} -> {:noreply, load(socket, socket.assigns.options)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
      end
    end
  end

  def handle_event("remove_environment", %{"name" => name}, socket) do
    scope = socket.assigns.current_scope

    case Teardown.environment(scope, name) do
      {:ok, removed} ->
        {:noreply,
         socket
         |> put_flash(:info, removed_summary(name, removed))
         |> load(socket.assigns.options)}

      # The row is gone either way, so this is not an error the user can retry
      # into success — it is a list of things to go and delete by hand. Naming
      # them is the whole value: a DNS record left pointing at a released
      # address is the one leftover that becomes somebody else's server.
      {:error, {:left_behind, left}, removed} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           removed_summary(name, removed) <>
             " Still there, and worth removing by hand: " <>
             Enum.map_join(left, ", ", & &1.location)
         )
         |> load(socket.assigns.options)}
    end
  end

  def handle_event("refresh_backups", _params, socket) do
    dumps = list_backups(socket)

    {:noreply,
     socket
     |> assign(:backups, dumps)
     |> assign(:backup_health, Backups.health(dumps, step_opts()))}
  end

  # The artifacts a deploy assumes it can find. `Generators.audit/2` says what
  # is missing and why; this is the button that puts it there, so a project
  # that predates the generator does not have to be recreated to become
  # deployable (story 970).
  def handle_event("generate_project", _params, socket) do
    scope = socket.assigns.current_scope
    project = project(scope)

    case DeployArtifacts.generate(scope.environment,
           app: DeployArtifacts.otp_app_name(project),
           host: project.domain || "example.com",
           owner: System.get_env("GITHUB_SPEX_OWNER") || "your-org"
         ) do
      {:ok, []} ->
        {:noreply,
         socket
         |> put_flash(:info, "Every deploy file is already in place.")
         |> load(socket.assigns.options)}

      {:ok, written} ->
        {:noreply,
         socket
         |> put_flash(:info, "Wrote #{Enum.join(written, ", ")}.")
         |> load(socket.assigns.options)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not generate: #{inspect(reason)}")}
    end
  end

  def handle_event("start_setup", _params, socket) do
    # Refused before the first step, not partway through it. A run that starts
    # without its credentials fails after it has already made things, and the
    # fix then involves deleting a server rather than entering a key
    # (criterion 7985).
    case Credentials.missing(socket.assigns.current_scope) do
      [] ->
        # Started, not awaited. The page stays responsive and each step's
        # transition arrives as it happens, which is what makes the run
        # watchable rather than a wait (criteria 7960, 7972).
        # With `step_opts()`, like every other run. Without them a full run got
        # none of what a single step gets — no provider options, no target
        # organisation, no injected probe — so it behaved differently from
        # running the same steps one at a time, which is the one thing a
        # "run everything" button must not do.
        {:ok, _pid} =
          Provisioning.run_async(
            socket.assigns.current_scope,
            socket.assigns.options,
            step_opts()
          )

        {:noreply, assign(socket, halted_at: nil, halt_reason: nil)}

      missing ->
        {:noreply,
         socket
         |> assign(:missing_credentials, missing)
         |> put_flash(
           :error,
           "Setup needs " <> Enum.map_join(missing, ", ", & &1.label) <> " before it can start."
         )}
    end
  end

  def handle_event("check_domain", %{"domain" => %{"name" => name}}, socket) do
    name = String.trim(name)
    scope = socket.assigns.current_scope

    # Adoption is checked first, and it is an ordinary way in rather than an
    # error path: a domain Sam already owns needs no purchase offer at all,
    # and showing him a price for something he has is worse than useless.
    case Cloudflare.owned?(scope, name) do
      {:ok, true} ->
        {:noreply,
         socket
         |> assign(domain_name: name, domain_check: nil, domain_error: nil)
         |> adopt_domain(name)}

      _ ->
        case Cloudflare.check_availability(scope, name) do
          {:ok, check} ->
            {:noreply, assign(socket, domain_name: name, domain_check: check, domain_error: nil)}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               domain_name: name,
               domain_check: nil,
               domain_error: describe_domain_error(reason)
             )}
        end
    end
  end

  def handle_event("confirm_purchase", _params, socket) do
    scope = socket.assigns.current_scope
    name = socket.assigns.domain_name

    # `ensure_domain` rather than `register_domain`: a retry must adopt what
    # the last attempt bought rather than buy a second one, and that decision
    # belongs in the context where every caller gets it.
    case Cloudflare.ensure_domain(scope, name, confirmed: true) do
      {:ok, :adopted} ->
        {:noreply, socket |> assign(domain_check: nil) |> adopt_domain(name)}

      {:ok, _body} ->
        {:noreply,
         socket
         |> assign(domain_check: nil, domain_error: nil)
         |> register_domain_on_project(name, false)}

      {:paused, message} ->
        {:noreply, assign(socket, domain_check: nil, domain_error: message)}

      {:error, reason} ->
        {:noreply, assign(socket, domain_error: describe_domain_error(reason))}
    end
  end

  def handle_event("put_secret", %{"secret" => params}, socket) do
    scope = socket.assigns.current_scope

    case Steps.put_secret(
           scope,
           params["environment"] || hd(environments(socket.assigns.current_scope)),
           String.trim(params["key"] || ""),
           params["value"] || ""
         ) do
      {:ok, %{key: key, environment: environment}} ->
        {:noreply,
         socket
         |> assign(:secret_error, nil)
         |> put_flash(:info, "Encrypted #{key} into #{environment}.")
         |> load(socket.assigns.options)}

      {:error, reason} ->
        {:noreply, socket |> assign(:secret_error, reason) |> load(socket.assigns.options)}
    end
  end

  def handle_event("confirm_apex_repoint", _params, socket) do
    scope = socket.assigns.current_scope

    # Re-run the step with the decision Sam just made. The guard refuses only
    # when it has not been told; being told is the whole difference between a
    # safeguard and an obstacle.
    #
    # Async for the same reason the plain "Run" button is (fdfdfb67): a dns
    # confirm fans the step out over every permitted environment, each paying
    # up to ~33s of resolver settle+retry (issue 74b6e3a0) — two environments
    # alone push this past the point a LiveView event should hold the socket.
    # No separate halt-reason plumbing is needed: the step's own row carries
    # its error the same way any other step's does, through
    # `{:provisioning, :step, row}` → `load/2` → a fresh `plan` read.
    :ok = Provisioning.run_step_async(scope, :dns, step_opts() ++ [confirm_apex_repoint: true])

    {:noreply,
     socket |> assign(halted_at: nil, halt_reason: nil) |> load(socket.assigns.options)}
  end

  def handle_event("adopt_repository", _params, socket) do
    scope = socket.assigns.current_scope

    # Adopt the repository that collided: re-run the step forcing adoption,
    # which is the choice Sam just made rather than one setup made for him.
    # Async for the same reason as confirm_apex_repoint above (issue 74b6e3a0).
    :ok = Provisioning.run_step_async(scope, :repository, step_opts() ++ [adopt: true])

    {:noreply,
     socket |> assign(halted_at: nil, halt_reason: nil) |> load(socket.assigns.options)}
  end

  def handle_event("rename_repository", _params, socket) do
    # Naming a different repository is a project edit — send Sam to the
    # project form rather than inventing a suffix on his behalf.
    {:noreply,
     push_navigate(socket,
       to: ~p"/app/projects/#{socket.assigns.current_scope.active_project.id}/edit"
     )}
  end

  def handle_event("check_credentials", _params, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:credentials, Credentials.list(scope, check?: true))
     |> assign(:missing_credentials, Credentials.missing(scope))}
  end

  def handle_event("resume_setup", _params, socket) do
    # With `step_opts()`, like every other path that runs a step. Resuming
    # without them gave the run no provider options, no target organisation
    # and no injected probe — so a resumed run behaved differently from the
    # same steps run any other way, which is the one thing resume must not do.
    result =
      Provisioning.resume(
        socket.assigns.current_scope,
        socket.assigns.options,
        step_opts()
      )

    {:noreply, apply_result(socket, result)}
  end

  # Retry is the same call as run — a step verifies before it acts, so
  # retrying one step is running it, and a separate "retry" path would be a
  # second implementation of the same thing that could drift.
  # Started, not awaited. A deploy provisions a builder, builds an image,
  # pushes it and runs kamal — minutes of work. Held inside this event it
  # blocked a drill's `render_click` for 1203 seconds before the client gave
  # up, and no socket survives that. It also killed the run: a builder was left
  # running on the account because `Builder.destroy` never got to execute.
  #
  # The page follows the same way it already follows a whole-sequence run.
  # `mark/3` broadcasts every transition and each step renders its own reason
  # from its own row, so nothing here has to hold the answer.
  def handle_event("run_step", %{"key" => key}, socket) do
    scope = socket.assigns.current_scope

    :ok = Provisioning.run_step_async(scope, String.to_existing_atom(key), step_opts())

    {:noreply,
     socket
     |> assign(halted_at: nil, halt_reason: nil)
     |> load(socket.assigns.options)}
  end

  # 4ed72738: the plain "Run" button above carries no form data — a paused
  # `inbound` step asking for an address Sam has to supply had nothing that
  # could ever answer it, and looped back to the identical pause forever.
  # `inbound_probe_to` is the one opt `default_inbound_probe/3` reads for
  # this; every other step ignores an opt key it doesn't recognise, so
  # sending it through `step_opts()` on a single-step re-run is safe.
  def handle_event("run_step_with_probe_address", %{"key" => key, "probe_to" => address}, socket)
      when is_binary(address) and address != "" do
    scope = socket.assigns.current_scope

    :ok =
      Provisioning.run_step_async(
        scope,
        String.to_existing_atom(key),
        [inbound_probe_to: address] ++ step_opts()
      )

    {:noreply,
     socket
     |> assign(halted_at: nil, halt_reason: nil)
     |> load(socket.assigns.options)}
  end

  # Which credentials a run needs is a function of the options; whether each is
  # on file is the part that costs something to find out. `load/2` holds both
  # with `assign_new` because re-proving on every event and every PubSub
  # announce was making provider calls from the wrong process — but that also
  # froze the *set*, so turning an option off left its credentials on screen
  # until a reload.
  #
  # Stale would be forgivable if it were only a list. It is a blocker: the page
  # says "Setup cannot start yet — still needed: Hetzner S3 access key ID" for
  # a run that will never use it, and those keys cannot be minted through an
  # API — the page's own directions send you to the Hetzner console, where they
  # are shown once. Believing it costs a trip for a credential nobody needs.
  #
  # Recomputed from the new options, reusing the checks already made rather
  # than asking any provider again. `list/1` without `check?` only reads
  # storage, and `missing/1` the same.
  #
  # Rebuilt rather than filtered. Filtering the list already on the socket can
  # only ever remove, so turning an option back on could not bring its
  # credential back — the row stayed gone until a remount.
  #
  # It also took its option list straight from the form params, which are
  # strings, and handed them to `required/1`, which compares against the
  # catalogue's atoms. `MapSet.member?(["storage"], :storage)` is false, so
  # every option-scoped credential failed the test and only the two
  # `options: :always` entries survived — the panel collapsed to GitHub and the
  # Hetzner API token on *any* toggle, whatever was actually enabled. The scope
  # is the atom-typed source of truth, so it is what we read.
  defp reselect_credentials(socket) do
    scope = socket.assigns.current_scope
    known = Map.new(socket.assigns.credentials, &{&1.key, &1})

    credentials =
      Enum.map(Credentials.list(scope), &carry_known_state(&1, Map.get(known, &1.key)))

    socket
    |> assign(:credentials, credentials)
    |> assign(:missing_credentials, Credentials.missing(scope))
  end

  # A toggle changes which credentials matter, not whether they passed. Only a
  # stored-but-unchecked row inherits, so a credential that has since gone
  # missing cannot carry an old "verified" forward.
  defp carry_known_state(%{state: "unchecked"} = credential, %{state: prior} = known)
       when prior in ["verified", "rejected"],
       do: %{credential | state: prior, missing_permission: known.missing_permission}

  defp carry_known_state(credential, _known), do: credential

  defp removed_summary(name, []), do: "Removed #{name}. It had nothing provisioned."

  defp removed_summary(name, removed),
    do: "Removed #{name}, and with it: " <> Enum.map_join(removed, ", ", & &1.location) <> "."

  # Says what actually goes, so the dialog is not a generic "are you sure".
  defp remove_environment_warning(%{host: host, server_name: server})
       when is_binary(server) and server != "" do
    "This destroys the server #{server}" <>
      if(is_binary(host) and host != "", do: " and removes the DNS record for #{host}", else: "") <>
      ". The record goes first, so the name stops resolving before the address is released."
  end

  defp remove_environment_warning(%{host: host}) when is_binary(host) and host != "" do
    "This removes the DNS record for #{host}. No server was ever provisioned for it."
  end

  defp remove_environment_warning(_environment),
    do: "Nothing was provisioned for it, so this only removes the row."

  # `key=value key=value` — the shape every proof resource uses for its
  # identifier, so the page can pull one field without knowing the order.
  defp proof_field(identifier, key) do
    identifier
    |> to_string()
    |> String.split(" ")
    |> Enum.find_value(fn part ->
      case String.split(part, "=", parts: 2) do
        [^key, value] -> value
        _ -> nil
      end
    end)
  end

  # Blank means "leave it alone", not "clear it". The field renders empty for a
  # secret that is already set — because the value is never sent back to the
  # browser — so treating blank as a delete would wipe every other credential
  # each time one was saved.

  # The path and expectation the render check fetches back. Both are required
  # by `verify_render/2`; a publish with nothing to look for could only ever
  # report success.
  defp publish_opts(socket) do
    [
      path: socket.assigns[:content_publish_path] || "/",
      expect: socket.assigns[:content_publish_expect] || "<html",
      # The site to fetch the post back from. Without it `verify_render/2` falls
      # through to `published[:site_url]`, which the publish does not set, and
      # builds a URL of "/" — dying inside Finch with `scheme is required for
      # url: /`, an error naming neither the site nor the step that wanted one.
      #
      # The publish's whole claim is that the post rendered somewhere a reader
      # can reach, so the address to check is not optional.
      site_url: site_url(socket.assigns.project.domain)
    ]
  end

  defp default_inbound_address(scope, domain) do
    local = scope.user.email |> to_string() |> String.split("@") |> List.first()
    "#{local}@#{domain}"
  end

  defp inbound_probe_result(scope, to) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    case Provisioning.probe_inbound(scope, to) do
      {:ok, message} ->
        %{
          state: "delivered",
          destination: to,
          message_id: message["id"],
          completed_at: message["created_at"] || now,
          # Forwarded to a mailbox is not the same as reaching the app. This
          # message came back through Resend's receiving API, so the app is
          # holding it — which is what 8048 asks and what a plain MX forward
          # to somebody's inbox would not satisfy.
          delivered_to: "app",
          body_available: message_body?(message),
          # Resend delivered it to the app itself. Nobody set up a forwarding
          # rule in a mail client to make that happen, which is the difference
          # 8048 is drawing: an inbox Sam has to babysit is not an inbox the
          # app owns.
          manual_forward: false,
          summary: "delivered to #{to}"
        }

      {:error, reason} ->
        %{
          state: "undelivered",
          destination: to,
          message_id: nil,
          completed_at: now,
          delivered_to: nil,
          body_available: false,
          manual_forward: nil,
          summary: "not delivered to #{to}: #{String.slice(to_string(reason), 0, 200)}"
        }
    end
  end

  # Acting on a message means reading it. A receipt with no body is a
  # notification that something arrived, which is not the same claim.
  defp message_body?(message) do
    Enum.any?(["text", "html"], fn key ->
      case message[key] do
        value when is_binary(value) and value != "" -> true
        _ -> false
      end
    end)
  end

  # A record deleted after verification is noticed some other way now: every
  # render's `plan` comes from `Provisioning.plan/2`, which re-derives step
  # verification live rather than trusting `current_scope.active_project`'s
  # cached fields — the only field this LiveView ever reads off
  # `active_project` is `.id` (line ~1938), which a reload could never change.
  # `confirm_apex_repoint`/`adopt_repository` were the last callers of a
  # reload that reloaded nothing anyone read (issue 74b6e3a0).

  @impl true
  def handle_info({:provisioning, :step, row}, socket) do
    socket = load(socket, socket.assigns.options)

    # `load/2` keeps the cached mail state; the steps that actually change it
    # say so here, so a page that just registered a sending domain shows it
    # without every other announce paying for a Resend round-trip.
    {:noreply, if(row.key in [:email, :inbound], do: refresh_mail(socket), else: socket)}
  end

  def handle_info({:provisioning, :finished, result}, socket) do
    {:noreply, apply_result(socket, result)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp apply_result(socket, %{halted_at: halted_at, reason: reason}) do
    socket
    |> load(socket.assigns.options)
    |> assign(halted_at: halted_at, halt_reason: reason)
  end

  defp load(socket, options) do
    plan = Provisioning.plan(socket.assigns.current_scope, options)

    socket
    |> assign_new(:backups, fn -> [] end)
    |> assign_new(:backup_health, fn -> nil end)
    |> assign_new(:restore_result, fn -> nil end)
    |> assign(:environment_rows, Provisioning.environments(socket.assigns.current_scope))
    |> assign(:options, options)
    |> assign(:available_options, available_options())
    |> assign(:plan, plan)
    |> assign(:resources, owned_resources(plan))
    # Held, not re-proved. `Credentials.list/1` and `missing/1` prove each
    # credential with a real provider call, and `load/2` runs on every event
    # *and* on every PubSub announce a step makes — so a run that marked four
    # steps fired four rounds of provider calls from a process that was not
    # the one driving the run. Under a sequential cassette those landed at
    # nondeterministic points, which is what made replays flaky: whether an
    # announce arrived inside or outside the cassette block decided whether it
    # consumed an interaction or hit the network. Credentials are proved when
    # they are saved and when Sam asks — `refresh_credentials/1`.
    |> assign_new(:credentials, fn -> credentials(socket.assigns.current_scope) end)
    |> assign_new(:missing_credentials, fn ->
      Credentials.missing(socket.assigns.current_scope)
    end)
    |> assign(
      :sops_recipients,
      Steps.recipients(socket.assigns.current_scope, environments(socket.assigns.current_scope))
    )
    |> assign(:age_key_environments, age_key_environments(socket.assigns.current_scope))
    |> assign(:secret_sources, secret_sources(socket.assigns.current_scope))
    |> assign_new(:secret_error, fn -> nil end)
    |> assign_new(:domain_name, fn -> nil end)
    |> assign_new(:domain_check, fn -> nil end)
    |> assign_new(:domain_error, fn -> nil end)
    |> assign(:domain_registered, registered_domain(socket.assigns.current_scope))
    |> then(fn socket ->
      names = environments(socket.assigns.current_scope)
      Process.put(:cms_environment_names, names)
      assign(socket, :environments, names)
    end)
    |> assign(:storage_ready?, Storage.credentials(socket.assigns.current_scope, []) != :none)
    # Read once and kept, not re-read on every event. `mail_state/2` and
    # `mail_domains/1` each call Resend live, so re-reading here meant three
    # provider round-trips per button click — slow, rate-limit-prone, and
    # nondeterministic under a sequential cassette, where a spex that clicked
    # one more time than the recording consumed an interaction that was not
    # there. `refresh_mail/1` re-reads when mail could actually have changed.
    |> then(fn socket ->
      # No provider call while mounting. `mail_state/3` and `mail_domains/2`
      # both reach Resend, and a mount cannot be covered by a cassette — the
      # idiom everywhere is mount, then act under one — so every page load with
      # a project domain put a `GET /domains` where no recording could reach
      # it. On replay that raises `cannot find mock/stub …Resend`, which names
      # process scoping and sends the reader after a `Req.Test` sharing problem
      # that is not there.
      #
      # `:if={@mail}` on the section means nil is a rendered state, not a
      # crash: the panel is absent until there is something to say. It fills in
      # from `refresh_mail/1`, which already runs when the email or inbound
      # step finishes — the moment its contents could have changed, and inside
      # whatever cassette the caller opened to run that step.
      socket
      |> assign_new(:mail, fn -> nil end)
      |> assign_new(:mail_domains, fn -> [] end)
    end)
    |> assign_new(:mail_send_result, fn -> nil end)
    |> assign_new(:mail_inbound_result, fn -> nil end)
    |> assign_new(:widget_degradation, fn -> nil end)
    |> assign_new(:content_publish, fn -> nil end)
    |> assign_new(:storage_objects, fn -> [] end)
    |> assign_new(:storage_readbacks, fn -> [] end)
    |> assign_new(:halted_at, fn -> nil end)
    |> assign_new(:halt_reason, fn -> nil end)
  end

  # The bucket a resource belongs to encodes its environment as a suffix, which
  # is what makes criterion 8012 checkable from the page: a UAT upload and a
  # production one are distinguishable without asking the provider.
  # The steps that fan out over environments tag what they made, because the
  # page cannot know the names: a project may have `qa`, or one environment per
  # story. Matching a hardcoded list against a location suffix only ever found
  # the two that used to be hardcoded.
  defp resource_environment(resource) do
    tagged(resource) || suffixed(resource)
  end

  # Steps that fan out over environments tag what they made, because the page
  # cannot know the names: a project may have `qa`, or one per story.
  defp tagged(%{identifier: identifier}) when is_binary(identifier) do
    case Regex.run(~r/environment=([a-z0-9-]+)/, identifier) do
      [_, environment] -> environment
      nil -> nil
    end
  end

  defp tagged(_), do: nil

  # Not everything carries the tag. A bucket encodes its environment as a
  # suffix on the name — `app-uat` — and that is what makes criterion 8012
  # checkable from the page at all. Reading only the tag reported every bucket
  # as belonging to no environment.
  #
  # Matched against the project's own environments rather than a pattern, so a
  # name that merely happens to end in `-something` is not mistaken for one.
  defp suffixed(%{location: location}) when is_binary(location) do
    Enum.find(environment_names(), fn environment ->
      String.ends_with?(location, "-" <> environment)
    end)
  end

  defp suffixed(_), do: nil

  # Read from the process dictionary rather than threaded through every render
  # helper: `resource_environment/1` is called from four places in the template
  # and the list is the same for the whole render.
  defp environment_names do
    Process.get(:cms_environment_names, [])
  end

  # The IP an environment's record points at — the first half of the tagged
  # identifier the DNS step writes.
  defp resource_target(%{identifier: identifier}) when is_binary(identifier),
    do: identifier |> String.split(" ") |> List.first()

  defp resource_target(_), do: nil

  # Only a built image reports one — an image that already existed was not
  # built here, so this page has nothing to say about what it was built for.
  # Absent rather than guessed, for the same reason the build reads it off the
  # image instead of echoing the request.
  defp image_architecture(resource), do: identifier_field(resource, "architecture")

  # Resources tag their identifier as `key=value key=value`, which several
  # steps already rely on. Read by name rather than by position: a resource
  # that gains a field should not silently shift what another attribute means.
  defp identifier_field(%{identifier: identifier}, key) when is_binary(identifier) do
    identifier
    |> String.split(" ")
    |> Enum.find_value(fn part ->
      case String.split(part, "=", parts: 2) do
        [^key, value] -> value
        _ -> nil
      end
    end)
  end

  defp identifier_field(_resource, _key), do: nil

  # Recorded by the provider rather than asserted by the page. Story 968's
  # whole claim is that these are Sam's, so a hardcoded "user" would make the
  # attribute decorative — it would read the same for a platform-owned bucket.
  # The bare name, not the endpoint-qualified location. Isolation is checked
  # by comparing one environment's bucket against another's, and that reads
  # far better as `app-uat` vs `app-prod` than as two URLs differing in a
  # suffix.
  defp format_probe_error(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp format_probe_error(reason), do: reason |> inspect() |> String.slice(0, 200)

  defp resource_name(%{location: location}) when is_binary(location),
    do: location |> String.split("/") |> List.last()

  defp resource_name(_), do: nil

  defp resource_disposition(%{kind: "repository", identifier: d}) when is_binary(d), do: d
  defp resource_disposition(_), do: nil

  defp resource_owner(%{kind: "bucket", identifier: owner}) when is_binary(owner), do: owner
  defp resource_owner(_), do: "user"

  defp project(scope), do: scope.active_project

  # The project's environments. Was a module attribute holding ["prod","uat"],
  # which made a `qa` or per-story environment invisible to the page even once
  # the rest of the system supported it.
  defp environments(scope), do: Provisioning.environment_names(scope)

  # Age in whole days, so the page can answer "is anything older than the
  # retention window still here?" without the reader doing date arithmetic.
  defp age_days(%{taken_at: taken_at}) when is_binary(taken_at) do
    case DateTime.from_iso8601(taken_at) do
      {:ok, at, _} -> DateTime.diff(now(), at, :day)
      _ -> 0
    end
  end

  defp age_days(_), do: 0

  defp now, do: Keyword.get(step_opts(), :now, &DateTime.utc_now/0).()

  # Every environment's bucket, because "is there a dump?" is a question about
  # the whole project — a prod bucket filling up while uat's has been empty for
  # a month is exactly the state a single-bucket view hides.
  defp list_backups(socket) do
    scope = socket.assigns.current_scope
    opts = socket.assigns.options
    project = project(scope)

    case Storage.credentials(scope, opts) do
      :none ->
        []

      {:ok, credentials} ->
        for environment <- environments(scope),
            bucket = Storage.bucket_name(project, environment),
            {:ok, dumps} <- [Storage.list_dumps(bucket, credentials, opts)],
            dump <- dumps do
          Map.merge(dump, %{environment: environment, bucket: bucket, age_days: age_days(dump)})
        end
    end
  end

  # Mail state is cached across events; re-read it when a step that changes it
  # has just run.
  defp refresh_mail(socket) do
    scope = socket.assigns.current_scope
    domains = list_domains(scope)

    socket
    |> assign(:mail, mail_state(scope, "prod", domains))
    |> assign(:mail_domains, mail_domains(scope, domains))
  end

  # Read from Resend every time rather than from the step row. The step
  # records what was true when it ran; this section is where Sam looks to find
  # out whether it is still true, which is a different question — a DNS record
  # deleted after verification is exactly the case the stored state cannot
  # see, and goes on reporting verified forever.
  # Every environment, because a sending domain per environment is the whole
  # of criterion 8056 — one shared domain means test mail and production mail
  # are indistinguishable to a recipient.

  defp mail_domains(scope, domains) do
    scope
    |> environments()
    |> Enum.map(&mail_state(scope, &1, domains))
    |> Enum.reject(&is_nil/1)
  end

  # Nothing to look up without a project domain, and asking anyway is a real
  # cost: `mail_state/3` used to short-circuit on this before it reached
  # Resend, so hoisting the listing out of it made every page that has no
  # domain yet call the provider to be told about domains it cannot match.
  # That is a round-trip per render on the most common early state, and it put
  # a `GET /domains` into spex whose cassettes had never seen one.
  defp list_domains(%{active_project: %{domain: d}} = scope) when is_binary(d) and d != "" do
    case Resend.list_domains(scope) do
      {:ok, domains} when is_list(domains) -> domains
      _ -> []
    end
  end

  defp list_domains(_scope), do: []

  # Verification waits are a property of DNS, not of the code, so they are
  # configurable rather than baked in. A freshly published record needs longer
  # to become visible to the provider than an already-propagated one, which is
  # the difference between a first run and a re-run — and between recording a
  # spex from cold and exercising a domain that has been live for months.
  # When the step finished. A `done` row's `updated_at` is that moment, and
  # criterion 8026 compares it against the verification timestamp to check
  # setup waited rather than declaring victory first.
  defp step_verified_at(%{verified_at: %DateTime{} = at}), do: DateTime.to_iso8601(at)
  defp step_verified_at(_), do: nil

  defp step_started_at(%{started_at: %DateTime{} = at}), do: DateTime.to_iso8601(at)
  defp step_started_at(_), do: nil

  defp step_completed_at(%{state: :done, completed_at: %DateTime{} = at}),
    do: DateTime.to_iso8601(at)

  defp step_completed_at(_step), do: nil

  defp step_opts do
    Application.get_env(:code_my_spec, :provisioning_step_opts, [])
  end

  # A configured site takes precedence over the one derived from the domain.
  #
  # Unset in production, where the project's own domain over https is the site
  # and anything else would verify a render on a page nobody visits. It exists
  # so a local site can be the publish target — the fleet's generated app on
  # loopback — which is what lets "the post appears on the live site" be checked
  # against a site that actually renders it rather than a recorded response.
  defp site_url(name) do
    :code_my_spec
    |> Application.get_env(:provisioning_step_opts, [])
    |> Keyword.get(:site_url)
    |> site_url_or_domain(name)
  end

  defp site_url_or_domain(configured, _name) when is_binary(configured) and configured != "",
    do: configured

  defp site_url_or_domain(_configured, name) when is_binary(name) and name != "",
    do: "https://#{name}"

  defp site_url_or_domain(_configured, _name), do: nil

  # Split into clauses rather than one `case` of map literals. Each field was
  # read as `probe[:key] || probe["key"]`, and eight of those in one body is
  # eight branches — the handler measured at complexity 13 for what is really
  # three outcomes.
  # `console_errors: "0"` used to sit in the first of these. Nothing counted
  # anything — an HTTP GET cannot see a console — so the page reported zero
  # errors on every successful probe, and a criterion asserting on it was
  # reading a constant. Removed rather than made nil: a field that can only
  # ever be empty invites someone to assert on it again.
  defp widget_degradation({:ok, probe}) do
    %{
      page_status: to_string(probe_field(probe, :page_status)),
      page_usable: probe_field(probe, :page_usable),
      widget_state: probe_field(probe, :widget_state),
      summary: "the page served, and claimed no widget connection"
    }
  end

  defp widget_degradation({:error, probe}) do
    %{
      page_status: to_string(probe_field(probe, :page_status)),
      page_usable: false,
      widget_state: probe_field(probe, :widget_state) || "unknown",
      summary: "the page did not serve"
    }
  end

  defp widget_degradation(_no_site) do
    %{
      page_status: nil,
      page_usable: false,
      widget_state: "unknown",
      summary: "no domain set on the project — nothing to probe"
    }
  end

  # Atom keys when the probe came from our own code, string keys once it has
  # been through JSON. The page cannot tell which it is holding.
  defp probe_field(probe, key), do: Map.get(probe, key) || Map.get(probe, Atom.to_string(key))

  # Write, then read back. One operation from the page's point of view: either
  # the object landed and came back byte-identical, or there is a reason it did
  # not. Extracted from the handler, which was three levels deep in nested
  # `case` and hid that shape.
  defp storage_probe(bucket, key, content, credentials, environment) do
    case Storage.put_object(bucket, key, content, credentials) do
      :ok ->
        object = %{key: key, environment: environment, bucket: bucket}
        {[object], [storage_readback(bucket, key, content, credentials, environment)]}

      # The provider's own words, not "error". A probe that failed without
      # saying why sends Sam to look at a bucket that is fine.
      {:error, reason} ->
        {[], [probe_failure(key, environment, reason)]}
    end
  end

  # "Matches" is the claim, so a 200 carrying different bytes is a failure and
  # says so rather than reading as a successful read.
  defp storage_readback(bucket, key, content, credentials, environment) do
    case Storage.get_object(bucket, key, credentials) do
      {:ok, ^content} ->
        %{key: key, environment: environment, status: "200", matches: true, reason: nil}

      {:ok, _other} ->
        %{
          key: key,
          environment: environment,
          status: "200",
          matches: false,
          reason: "bytes differ"
        }

      {:error, reason} ->
        probe_failure(key, environment, reason)
    end
  end

  defp probe_failure(key, environment, reason) do
    %{
      key: key,
      environment: environment,
      status: "error",
      matches: false,
      reason: format_probe_error(reason)
    }
  end

  # The deploy step renders its provider error a second time as `boot-failure`,
  # which criterion 8000 selects on to prove the missing secret is named. One
  # fact, two elements — and the escalation printing it as well made the step
  # look like it was reporting two separate problems. The escalation keeps
  # `attempted`, which is the part nothing else says.
  defp shown_again_below?(%{key: :deploy}), do: true
  defp shown_again_below?(_step), do: false

  # Each resource with whether its step still verifies. "What you now own" is a
  # claim about the present, and a recorded resource is only evidence of that
  # while the step that made it holds.
  #
  # `reverify/3` keeps the list when a step goes absent, deliberately —
  # teardown removes only what a step recorded, so clearing it would leak
  # whatever is still there (`provisioning.ex:498`). That is right, and it means
  # the record outlives the resource. The panel used to flatten the lists
  # regardless, so a server deleted at the provider was still listed under a
  # heading that says Sam owns it, on the same page load that discovered it was
  # gone.
  defp owned_resources(plan) do
    for step <- plan, resource <- step.resources do
      %{
        resource: resource,
        step: step.key,
        verified?: step.state == :done,
        verified_at: step.verified_at
      }
    end
  end

  defp unverified_note(%{verified_at: %DateTime{} = at}),
    do: "not found #{Calendar.strftime(at, "%b %-d %H:%M")}"

  # No check on record either — a resource from a step that never finished.
  defp unverified_note(_owned), do: "unverified"

  # Takes the domain listing rather than fetching its own. `find_domain/2` is a
  # full `GET /domains` behind a filter, so reading three environments used to
  # cost three identical listings — and `refresh_mail/1` asked for prod twice
  # over, once on its own and once inside `mail_domains/1`.
  #
  # The count matters beyond the round-trips. It made the number of provider
  # calls a function of how many times the page happened to render rather than
  # of how much there was to read, and a sequential cassette replays exactly
  # the calls it recorded — so a replay that settled in one more render than
  # the recording ran out of interactions and failed on a green method and a
  # green uri. `ensure_dns_record/5` takes `:records` for the same reason.
  defp mail_state(scope, environment, domains) do
    with %{domain: base} when is_binary(base) and base != "" <- scope.active_project,
         sending <- Resend.sending_domain(base, environment),
         found when is_map(found) <- Enum.find(domains, &(&1["name"] == sending)),
         {:ok, domain} <- fetch_full_domain(scope, found) do
      # The list endpoint omits `records` entirely — only the single-domain
      # read carries them. Rendering from the list produced a mail section
      # that knew the domain was verified but could not say which records
      # made it so, which is the whole of criterion 8025.
      records = Resend.records(domain)

      %{
        domain: domain["name"],
        environment: environment,
        status: domain["status"],
        provider_id: domain["id"],
        attempts: verification_attempts(scope),
        verified_at: domain["created_at"],
        dkim: dkim_state(records),
        manual_step_required: domain["status"] not in ["verified", "pending"],
        # Resend's own records, plus whatever MX the zone actually publishes at
        # the apex. The provider lists only records it wants; an MX that was
        # already receiving mail is invisible there, and "did setup disturb my
        # existing mail" is a question about the zone (criterion 8029).
        records:
          Enum.map(records, &mail_record(&1, domain["name"])) ++
            apex_mx_records(domain["name"]),
        missing_records:
          records |> Enum.filter(&(&1["status"] == "not_started")) |> Enum.map(& &1["name"])
      }
    else
      _ -> nil
    end
  end

  defp fetch_full_domain(scope, %{"id" => id} = found) do
    case Resend.get_domain(scope, id) do
      {:ok, %{"data" => domain}} -> {:ok, domain}
      {:ok, domain} when is_map(domain) -> {:ok, domain}
      _ -> {:ok, found}
    end
  end

  # How many times setup actually asked the provider, recorded by the step
  # when it polled. Criterion 8026 is that setup *waited* rather than taking
  # the first pending answer, and only the step knows that — the domain's
  # current state cannot say how many times it was checked.
  defp verification_attempts(scope) do
    scope
    |> Provisioning.plan([:email])
    |> Enum.find(&(&1.key == :email))
    |> case do
      %{resources: resources} ->
        resources
        |> Enum.find(&(&1.kind == "verification"))
        |> case do
          %{location: location} -> location |> to_string() |> String.replace(~r/\D/, "")
          _ -> "0"
        end

      _ ->
        "0"
    end
  end

  # Resend names records relative to the **zone**, not the domain. For a
  # sending domain of `mail.example.com` in zone `example.com` the DKIM record
  # comes back as `resend._domainkey.mail`, so appending the domain yields
  # `resend._domainkey.mail.mail.example.com` — a name that will never
  # resolve, rendered as though it should.
  #
  # The same trap caught the inbound MX earlier. Zone, not domain.
  defp mail_record(record, base) do
    verified = record["status"] in ["verified", "success"]
    name = apex_or_qualified(record["name"], base)

    %{
      type: record["type"],
      # `@` for the apex, because that is how a zone file names it and how a
      # reader looking for "the apex MX" will search for it.
      name: name,
      verified: verified,
      # Asked of a resolver, not inferred from `verified`. The two are
      # different claims and they come apart in the direction that matters: a
      # provider holds a verification long after the record behind it is
      # deleted, so a domain reads verified while its DKIM is gone. Criterion
      # 8025 asks that records resolve *publicly*, which only a resolver can
      # answer.
      resolved: resolves?(name, base, record["type"]),
      content: record["value"]
    }
  end

  # Authoritative, because a recursive resolver caches the *absence* of a
  # record and setup asks this question moments after publishing one — the
  # exact window where a cached NXDOMAIN reports a record missing that is
  # demonstrably there.
  defp resolves?(name, base, type) do
    query = if name == "@", do: base, else: name

    record_type =
      case String.upcase(to_string(type)) do
        "MX" -> :mx
        "TXT" -> :txt
        "CNAME" -> :cname
        _ -> :a
      end

    # Over HTTPS, not through the system resolver. `lookup_authoritative/2` is
    # a DNS syscall: it cannot be recorded, so a spex asserting "this record
    # resolves" re-queried live DNS on replay and failed as soon as the record
    # it asserted on had been torn down. DNS-over-HTTPS is an ordinary request,
    # so it records and replays like every other provider call — and it still
    # genuinely leaves this machine, which is the claim being made.
    # Authoritative, and it has to be. A recursive resolver caches the
    # *absence* of a record for the zone's SOA negative TTL — 1800s on the
    # domains this runs against — and setup asks this question seconds after
    # publishing. Going through DNS-over-HTTPS (which is recursive) made a
    # freshly published record read as "does not resolve" for half an hour,
    # which is wrong in production, not just in a test.
    #
    # The cost is that this is a DNS syscall and so cannot be recorded, which
    # is why spex asserting on it re-query live DNS on replay. Making it
    # recordable needs an injected resolver seam here, not a recursive lookup.
    # Injectable so a spex can record the answer and replay it. Production has
    # no override and takes the authoritative lookup below.
    case Application.get_env(:code_my_spec, :dns_resolver) do
      resolver when is_function(resolver, 2) -> resolver.(query, record_type)
      _ -> Dns.lookup_authoritative(query, record_type) != []
    end
  end

  # Read from a resolver rather than from either provider. Cloudflare would
  # say what is configured; only a lookup says what the world sees.
  # The *project's* domain, not the registrable zone. For a customer who owns
  # `example.com` those are the same name; for a project on a subdomain they
  # are not, and looking at the zone reported a neighbour's inbound mail as
  # this project's — or missed this project's entirely.
  #
  # Through `resolves?/3` so it goes via the injected resolver, which is what
  # lets a spex record the answer and replay it rather than re-querying live
  # DNS for records it has since torn down.
  defp apex_mx_records(base) do
    if resolves?("@", base, "MX") do
      [%{type: "MX", name: "@", verified: true, resolved: true, content: base}]
    else
      []
    end
  end

  defp apex_or_qualified(name, _base) when name in [nil, "", "@"], do: "@"
  defp apex_or_qualified(name, base), do: qualify_record(name, base)

  defp qualify_record(name, base) when name in [nil, "", "@"], do: base

  defp qualify_record(name, base) do
    zone = base |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

    if String.ends_with?(name, zone), do: name, else: "#{name}.#{zone}"
  end

  # DKIM decides whether mail is trusted rather than merely sent, so it is
  # reported on its own rather than folded into a status that would read
  # "verified" with DKIM failing.
  defp dkim_state(records) do
    case Enum.find(records, &(String.upcase(to_string(&1["record"] || "")) =~ "DKIM")) do
      nil -> "unknown"
      %{"status" => status} when status in ["verified", "success"] -> "pass"
      _ -> "fail"
    end
  end

  defp credentials(scope), do: Credentials.list(scope)

  defp adopt_domain(socket, name), do: register_domain_on_project(socket, name, true)

  # The domain lands on the project, because every later step reads it from
  # there — the DNS records, the certificate and the deploy all resolve their
  # host from `project.domain`.
  defp register_domain_on_project(socket, name, adopted?) do
    scope = socket.assigns.current_scope

    case Projects.update_project(scope, scope.active_project, %{domain: name}) do
      {:ok, project} ->
        scope = %{scope | active_project: project}

        # Adopting completes the domain step: an existing domain is an
        # ordinary way in, so the step reads done rather than staying
        # not_started because it was reached through the check form rather
        # than the run button (criterion 8052).
        if adopted?, do: Provisioning.adopt_domain_step(scope, name)

        socket
        |> assign(:current_scope, scope)
        |> load(socket.assigns.options)

      {:error, _} ->
        assign(socket, :domain_error, "Could not record #{name} on the project.")
    end
  end

  defp firewall_rules, do: Hetzner.default_firewall_rules()

  defp availability_label(%{availability: :available}), do: "available"
  defp availability_label(%{availability: :taken}), do: "taken"
  defp availability_label(_), do: "check the dashboard"

  defp registered_domain(%{active_project: %{domain: d}} = scope) when is_binary(d) and d != "" do
    # Adopted-vs-bought is read from the domain step's recorded resource, not
    # guessed: the resource carries `origin: "adopted"` when setup found the
    # domain, and that is persisted — so a reload or a step broadcast does not
    # recompute an adopted domain as bought (which is what a bare project
    # lookup did, clobbering the flag every time the page reloaded).
    adopted? =
      case Provisioning.get_step(scope, :domain) do
        %{resources: resources} ->
          Enum.any?(resources, &(&1.kind == "domain" and &1.origin == "adopted"))

        _ ->
          false
      end

    %{name: d, adopted: adopted?}
  end

  defp registered_domain(_), do: nil

  defp describe_domain_error({_tag, status, _body}), do: "Cloudflare refused (#{status})."
  defp describe_domain_error(:confirmation_required), do: "Registration needs an explicit yes."
  defp describe_domain_error(reason) when is_binary(reason), do: reason
  defp describe_domain_error(reason), do: inspect(reason)

  defp age_key_environments(scope) do
    Enum.filter(environments(scope), &ProjectSecrets.has_value?(scope, "age_private_key_#{&1}"))
  end

  # Criterion 8002: the laptop and the deploy read the *same* committed files.
  # Rendered rather than asserted in prose so the claim is checkable, and so it
  # breaks if the two ever diverge.
  defp secret_sources(scope) do
    for consumer <- ["local", "deploy"], environment <- environments(scope) do
      %{consumer: consumer, path: Sops.env_file(environment)}
    end
  end

  # Never "not set" for a connection — Sam does not paste those, and telling
  # him a thing he connected on his account is unset sends him looking for a
  # field that is not there.
  defp credential_badge(%{state: "verified"}), do: "verified"
  defp credential_badge(%{state: "rejected"}), do: "rejected"
  defp credential_badge(%{stored?: true}), do: "set"
  defp credential_badge(%{kind: :connection}), do: "not connected"
  defp credential_badge(_), do: "not set"

  # Every option any step declares, in sequence order and without duplicates,
  # so the toggles are derived from the sequence rather than a second list
  # that could fall out of step with it.
  # Delegated rather than duplicated: the context derives this from the
  # sequence and now also persists against it, and two lists that must agree
  # eventually do not.
  defp available_options, do: Provisioning.available_options()
end
