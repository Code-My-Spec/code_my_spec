defmodule CodeMySpec.Provisioning.Steps do
  @moduledoc """
  Adapts each provider module to the one shape the sequence runs.

  ## Why this module exists at all

  No two providers share a signature. `Hetzner.ensure_server/3` takes a scope,
  `Deploy.run/3` takes an environment, `Repository.run/4` takes both plus the
  project, and `Sops.put_secret/5` takes an environment name and a private
  key. That is right for each of them in isolation — a provider should ask for
  what it needs — and useless to a sequencer, which needs one call it can make
  fourteen times.

  So the adapting happens here, once, rather than each provider being bent to
  a common interface it does not want.

  ## Two functions, and the difference matters

  - `verify/3` asks the provider whether the resource exists **right now**.
    Never reads persisted state. This is what makes a re-run converge and a
    resource deleted behind setup's back get rebuilt.
  - `run/3` does the work.

  A step that cannot be verified returns `{:ok, :absent}`, which means "run
  it". That is the safe default: running an idempotent step twice is
  harmless, whereas skipping one that was never done is a broken foundation.

  ## Steps with no provider yet

  Several steps have no module behind them — storage, backups, tls, inbound,
  callback_credential. They return `{:error, :not_implemented}` with the step
  named, so the sequence halts visibly rather than reporting done for work
  that never happened. Reporting success for an unimplemented step is the
  exact failure `Provisioning` exists to prevent, so it is better to be
  loudly incomplete.
  """

  alias CodeMySpec.Provisioning.{Cloudflare, ContentPublishing, Deploy, Hetzner, Repository, Resend, Widget}
  alias CodeMySpec.Users.Scope

  @type outcome ::
          {:ok, [map()]}
          | {:paused, String.t()}
          | {:error, term()}

  @type verdict ::
          {:ok, :satisfied, [map()]}
          | {:ok, :absent}
          | {:error, term()}

  ## Verify

  @doc """
  Whether a step's resource exists according to its provider.

  `{:ok, :absent}` means "not there, run it". Anything a provider cannot
  answer for is treated as absent rather than satisfied — a false "satisfied"
  skips real work, a false "absent" merely repeats an idempotent step.
  """
  @spec verify(atom(), Scope.t(), keyword()) :: verdict()
  def verify(:repository, %Scope{} = scope, opts) do
    project = project(scope)
    name = Keyword.get(opts, :name) || Repository.default_name(project)

    case Keyword.get(opts, :owner) do
      nil ->
        {:ok, :absent}

      owner ->
        case CodeMySpec.GitHub.get_repository(scope, owner, name) do
          {:ok, repo} -> {:ok, :satisfied, [repo_resource(repo)]}
          {:error, :not_found} -> {:ok, :absent}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def verify(:server, %Scope{} = scope, opts) do
    name = server_name(scope, opts)

    case Hetzner.find_server(scope, name) do
      {:ok, server} -> {:ok, :satisfied, [server_resource(server)]}
      {:error, :not_found} -> {:ok, :absent}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(:domain, %Scope{} = scope, _opts) do
    case domain(scope) do
      nil ->
        {:ok, :absent}

      name ->
        case Cloudflare.owned?(scope, name) do
          {:ok, true} -> {:ok, :satisfied, [%{kind: "domain", location: "cloudflare/#{name}"}]}
          {:ok, false} -> {:ok, :absent}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def verify(:email, %Scope{} = scope, opts) do
    environment = Keyword.get(opts, :environment, "prod")

    case domain(scope) do
      nil ->
        {:ok, :absent}

      base ->
        sending = Resend.sending_domain(base, environment)

        case Resend.find_domain(scope, sending) do
          {:ok, %{"status" => "verified"} = d} ->
            {:ok, :satisfied, [%{kind: "sending_domain", location: "resend/#{d["name"]}"}]}

          {:ok, _unverified} -> {:ok, :absent}
          {:error, :not_found} -> {:ok, :absent}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Everything else is either cheap to re-run or has no read-back that
  # distinguishes done from not-done without doing the work.
  def verify(_key, _scope, _opts), do: {:ok, :absent}

  ## Run

  @doc "Execute a step. See the moduledoc for the shape and why it is this one."
  @spec run(atom(), Scope.t(), keyword()) :: outcome()
  def run(:repository, %Scope{} = scope, opts) do
    project = project(scope)

    case Repository.run(scope, env(scope), project, opts) do
      %{state: :pushed, repository: repo, commit: commit} ->
        {:ok, [repo_resource(repo), %{kind: "commit", location: commit}]}

      %{state: :name_taken, reason: reason} ->
        {:paused, reason}

      %{reason: reason} ->
        {:error, reason}
    end
  end

  def run(:server, %Scope{} = scope, opts) do
    name = server_name(scope, opts)

    with {:ok, firewall} <- Hetzner.ensure_firewall(scope, name),
         {:ok, server} <- Hetzner.ensure_server(scope, name, Keyword.put(opts, :firewall_ids, [firewall["id"]])) do
      {:ok, [server_resource(server), %{kind: "firewall", location: "hetzner/#{name}"}]}
    else
      {:error, reason} -> {:error, format(reason)}
    end
  end

  def run(:domain, %Scope{} = scope, opts) do
    case domain(scope) do
      nil ->
        {:error, "no domain set on the project — set one before running the domain step"}

      name ->
        case Cloudflare.ensure_domain(scope, name, opts) do
          {:ok, :adopted} -> {:ok, [%{kind: "domain", location: "cloudflare/#{name}"}]}
          {:ok, _body} -> {:ok, [%{kind: "domain", location: "cloudflare/#{name}"}]}
          {:paused, instructions} -> {:paused, instructions}
          {:error, :confirmation_required} -> {:paused, confirmation_message(name)}
          {:error, reason} -> {:error, format(reason)}
        end
    end
  end

  def run(:dns, %Scope{} = scope, opts) do
    with name when is_binary(name) <- domain(scope),
         {:ok, zone} <- Cloudflare.find_zone(scope, name),
         {:ok, ip} <- server_ip(scope, opts),
         {:ok, _} <- Cloudflare.ensure_dns_record(scope, zone["id"], name, ip),
         {:ok, _} <- Cloudflare.ensure_dns_record(scope, zone["id"], "app.#{name}", ip) do
      {:ok, [%{kind: "dns_record", location: "cloudflare/#{name}"}]}
    else
      nil -> {:error, "no domain set on the project"}
      {:error, reason} -> {:error, format(reason)}
    end
  end

  def run(:email, %Scope{} = scope, opts) do
    environment = Keyword.get(opts, :environment, "prod")

    with base when is_binary(base) <- domain(scope),
         sending <- Resend.sending_domain(base, environment),
         {:ok, d} <- Resend.ensure_domain(scope, sending),
         {:ok, %{attempts: n}} <- Resend.poll_until_verified(scope, d["id"], opts) do
      {:ok,
       [
         %{kind: "sending_domain", location: "resend/#{sending}"},
         %{kind: "verification", location: "#{n} attempts"}
       ]}
    else
      nil ->
        {:error, "no domain set on the project"}

      {:error, {:unverified, faulted}} ->
        {:error,
         "the sending domain did not verify — these records are not as Resend expects: " <>
           Enum.map_join(faulted, ", ", & &1["name"])}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  def run(:deploy, %Scope{} = scope, opts) do
    environment = Keyword.get(opts, :environment, "uat")
    host = Keyword.get(opts, :host) || domain(scope)

    case Deploy.run(env(scope), environment, Keyword.put(opts, :host, host)) do
      %{swapped_at: nil, reason: reason} -> {:error, reason}
      %{swapped_at: _} -> {:ok, [%{kind: "deployment", location: "#{environment}/#{host}"}]}
    end
  end

  def run(:monitoring, %Scope{} = scope, opts) do
    hosts = Keyword.get(opts, :hosts) || List.wrap(domain(scope))

    case Deploy.ensure_monitors(hosts, opts) do
      {:ok, monitors} ->
        {:ok, Enum.map(monitors, &%{kind: "monitor", location: &1["friendly_name"] || "monitor"})}

      {:error, :no_notification_target} ->
        {:paused, "Add a notification target before installing monitors — a monitor nobody hears is not monitoring."}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  def run(:content, %Scope{} = scope, opts) do
    case ContentPublishing.run(scope, opts) do
      %{state: :rendered} -> {:ok, [%{kind: "content", location: "published and rendered"}]}
      %{reason: reason} -> {:error, reason}
    end
  end

  def run(:widget, %Scope{} = scope, opts) do
    case Widget.run(scope, env(scope), opts) do
      %{state: :proven} -> {:ok, [%{kind: "widget", location: "installed and proven"}]}
      %{reason: reason} -> {:error, reason}
    end
  end

  # Named rather than silently succeeding — see the moduledoc.
  def run(key, _scope, _opts), do: {:error, {:not_implemented, key}}

  ## Helpers

  defp project(%Scope{active_project: project}), do: project
  defp env(%Scope{environment: environment}), do: environment

  defp domain(%Scope{active_project: %{domain: d}}) when is_binary(d) and d != "", do: d
  defp domain(_), do: nil

  defp server_name(scope, opts) do
    Keyword.get(opts, :server_name) || Repository.default_name(project(scope))
  end

  defp server_ip(scope, opts) do
    case Hetzner.find_server(scope, server_name(scope, opts)) do
      {:ok, server} -> {:ok, get_in(server, ["public_net", "ipv4", "ip"])}
      other -> other
    end
  end

  defp repo_resource(repo) do
    %{kind: "repository", location: repo["full_name"] || repo["name"]}
  end

  defp server_resource(server) do
    %{
      kind: "server",
      location: "hetzner/#{get_in(server, ["datacenter", "location", "name"]) || "?"}/#{server["name"]}"
    }
  end

  defp confirmation_message(name) do
    "#{name} is available. Registering it costs money and is not refundable, " <>
      "so setup will not buy it without an explicit confirmation."
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
