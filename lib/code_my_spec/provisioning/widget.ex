defmodule CodeMySpec.Provisioning.Widget do
  @moduledoc """
  Installs the support widget on the deployed site and proves it works.

  Installation runs the existing generator (`cms_gen.support_widget`) through
  `CodeMySpec.Environments.cmd/4`. This module does not reimplement the widget.

  - **The generator is `cms_gen.support_widget`**, the one new projects ship
    (WebSocket transport, deploy-key auth) — not the deprecated
    `cms_gen.feedback_widget` or `client_utils.gen.chat_widget`.
  - **Presence is a published contract**: the generated widget emits
    `data-cms-widget`, `data-cms-widget-toggle` and `data-cms-widget-state`
    for outside probers (`markers/0`).
  - **Anonymous by design**: there is no option to make it members-only.
  - **Degradation**: `probe_degraded/2` checks from outside that the page
    still renders and does not claim a connection.
  - **Done means a message arrived** from the deployed site, with its origin
    recorded; markup can be right while the socket, credential or CORS is
    not.

  See knowledge/provisioning, "Widget".
  """

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Users.Scope

  @generator "cms_gen.support_widget"

  # The marker contract, in one place.
  @present_marker "data-cms-widget"
  @toggle_marker "data-cms-widget-toggle"

  @doc """
  The markers a prober looks for, as data.

  Published so the spex fakes serve the same markers the probes look for,
  rather than a copy that drifts from the contract.
  """
  @spec markers() :: %{present: String.t(), toggle: String.t(), state: String.t()}
  def markers,
    do: %{present: @present_marker, toggle: @toggle_marker, state: "data-cms-widget-state"}

  @type result :: %{
          state: :proven | :install_failed | :absent | :not_proven,
          install: map() | nil,
          presence: map() | nil,
          proof: map() | nil,
          proven_at: DateTime.t() | nil,
          reason: String.t() | nil
        }

  @doc """
  Run the widget generator against the project.

  Requires a deploy key because a widget installed without one cannot reach
  CodeMySpec; the generator reads it from the app's own config rather than
  from a flag, so this is a precondition rather than an argument.

  Returns the generator's output so a failure can be reported with what it
  actually said rather than "install failed".
  """
  @spec install(Environments.Environment.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def install(env, deploy_key, opts \\ []) when is_binary(deploy_key) do
    args = [@generator | Keyword.get(opts, :extra_args, [])]
    # `:mix_bin` lets a test point at a stub without mutating PATH.
    mix = Keyword.get(opts, :mix_bin, "mix")

    # `stderr_to_stdout`: Mix reports a missing task on stderr.
    case already_installed(env, opts) do
      nil ->
        case Environments.cmd(env, mix, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, %{output: output}}
          {output, status} -> {:error, "Widget generator failed (exit #{status}): #{output}"}
        end

      marker ->
        {:ok, %{output: "#{marker} is already present — generator not re-run"}}
    end
  end

  # The generator only once: it prompts before overwriting its own files, so
  # a second run waits forever for an answer. Installed files mean the install
  # is done; the presence and proof checks establish the rest. The files are
  # found from the checkout's own `lib/*_web`, not the project row's name.
  defp already_installed(env, opts) do
    case Keyword.get(opts, :installed_markers) do
      markers when is_list(markers) and markers != [] ->
        Enum.find(markers, &Environments.file_exists?(env, &1))

      _ ->
        Enum.find(widget_files(env), &Environments.file_exists?(env, &1))
    end
  end

  defp widget_files(env) do
    case Environments.list_directory(env, "lib") do
      {:ok, entries} ->
        for entry <- entries,
            String.ends_with?(entry, "_web"),
            do: "lib/#{entry}/live/support_widget_live.ex"

      _ ->
        []
    end
  end

  @doc """
  Whether the widget is present and openable on the live site.

  Both matter: present-but-not-openable is a broken bundle whose script tag
  still renders.
  """
  @spec verify_present(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def verify_present(site_url, opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &fetch/1)
    marker = Keyword.get(opts, :marker, @present_marker)

    case fetch.(site_url) do
      {:ok, %{status: 200, body: body}} ->
        present = String.contains?(body, marker)

        openable =
          present and String.contains?(body, Keyword.get(opts, :bundle_marker, @toggle_marker))

        presence = %{status: 200, present: present, openable: openable}

        if openable, do: {:ok, presence}, else: {:error, presence}

      {:ok, %{status: status}} ->
        {:error, %{status: status, present: false, openable: false}}

      {:error, reason} ->
        {:error, %{status: inspect(reason), present: false, openable: false}}
    end
  end

  @doc """
  Verify the page survives an unreachable backend.

  Passes when the page still answers 200, renders its own content, and does
  not claim `connected`. Over HTTP the widget's state is a dead render (no
  socket attempted), so only that negative is observable; watching it fail
  over needs a browser, in the generated application's own tests. A page with
  no widget ("absent") fails: it proves nothing.
  """
  @spec probe_degraded(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def probe_degraded(site_url, opts \\ []) do
    fetch = Keyword.get(opts, :fetch_degraded, Keyword.get(opts, :fetch, &fetch/1))

    case fetch.(site_url) do
      {:ok, %{status: 200, body: body}} ->
        usable =
          not String.contains?(body, Keyword.get(opts, :broken_marker, "Application error"))

        state = served_widget_state(body)
        probe = %{page_status: 200, page_usable: usable, widget_state: state}

        # "absent" fails too: a page with no widget proves nothing.
        if usable and state not in ["connected", "absent"],
          do: {:ok, probe},
          else: {:error, probe}

      {:ok, %{status: status}} ->
        {:error, %{page_status: status, page_usable: false, widget_state: "unknown"}}

      {:error, reason} ->
        {:error, %{page_status: inspect(reason), page_usable: false, widget_state: "unknown"}}
    end
  end

  # The published value, so "absent" and "unavailable" stay distinct.
  defp served_widget_state(body) do
    case Regex.run(~r/data-cms-widget-state="([^"]*)"/, body) do
      [_, state] -> state
      nil -> "absent"
    end
  end

  @doc """
  Whether a real message has arrived from the deployed site.

  `lookup` is given the scope and returns the messages CodeMySpec has received
  for the project. Only an origin of `deployed_site` counts: a message from a
  local dev server says nothing about where visitors are.
  """
  @spec message_proof(Scope.t(), keyword()) :: {:ok, map()} | {:error, :no_message}
  def message_proof(%Scope{} = scope, opts \\ []) do
    lookup = Keyword.fetch!(opts, :lookup)

    scope
    |> lookup.()
    |> Enum.find(&(origin(&1) == "deployed_site"))
    |> case do
      nil -> {:error, :no_message}
      message -> {:ok, %{state: "received", origin: "deployed_site", message: message}}
    end
  end

  defp origin(%{origin: origin}), do: to_string(origin)
  defp origin(%{"origin" => origin}), do: to_string(origin)
  defp origin(_), do: nil

  @doc """
  Install, verify, and prove — in that order.

  Returns a result whose `proven_at` is set only when a real message arrived.
  There is no field that says "done" independently of the proof. Each stage
  keeps what the ones before it learned, so a not-proven result still carries
  `install` and `presence`.
  """
  @spec run(Scope.t(), Environments.Environment.t(), keyword()) :: result()
  def run(%Scope{} = scope, env, opts \\ []) do
    site_url = Keyword.fetch!(opts, :site_url)
    deploy_key = Keyword.fetch!(opts, :deploy_key)

    case install(env, deploy_key, opts) do
      {:ok, install} -> check_presence(scope, install, site_url, opts)
      {:error, reason} -> %{blank() | state: :install_failed, reason: reason}
    end
  end

  defp check_presence(scope, install, site_url, opts) do
    case verify_present(site_url, opts) do
      {:ok, presence} ->
        check_proof(scope, install, presence, opts)

      {:error, presence} ->
        %{
          blank()
          | state: :absent,
            install: install,
            presence: presence,
            reason: "The widget is not usable on #{site_url} (#{inspect(presence)})."
        }
    end
  end

  @doc """
  Ask the deployed application to send a message through its own widget.

  The generated application exposes `POST /_cms/verify/widget`, which sends a
  message through its own client with its own deploy key, so a working install
  is proven without waiting for a visitor. It does not prove the browser half
  (bundle mounts, CORS); `verify_present/2` covers the served markup, and the
  resource records `via=loopback`.

  Failure is not fatal: older applications answer 404 and ones without the
  widget 501. The poll that follows is the real check.
  """
  @spec trigger_message(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def trigger_message(site_url, deploy_key, opts \\ []) do
    post = Keyword.get(opts, :post, &post_verify/3)
    probe = Keyword.get(opts, :probe, "cms-verify-#{System.unique_integer([:positive])}")

    post.(site_url <> "/_cms/verify/widget", deploy_key, probe)
  end

  defp post_verify(url, deploy_key, probe) do
    req_opts =
      [
        method: :post,
        url: url,
        json: %{probe: probe},
        headers: [{"authorization", "Bearer #{deploy_key}"}],
        retry: false,
        receive_timeout: 15_000
      ] ++ plug_opt()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, %{status: status, probe: probe, body: body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_proof(scope, install, presence, opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    # Ask before looking. Unchecked: a 404/501 is not evidence about the
    # widget, and a real visitor's message proves it just as well.
    ask_the_site_to_speak(opts)

    case message_proof(scope, opts) do
      {:ok, proof} ->
        %{
          blank()
          | state: :proven,
            install: install,
            presence: presence,
            proof: proof,
            proven_at: now.()
        }

      {:error, :no_message} ->
        %{
          blank()
          | state: :not_proven,
            install: install,
            presence: presence,
            reason:
              "The widget is installed and openable, but no message has travelled from the " <>
                "deployed site yet. Markup can be right while the socket, credential or CORS is not."
        }
    end
  end

  # The trigger, then a settle: the endpoint answers 202 before the message
  # makes its round trip.
  defp ask_the_site_to_speak(opts) do
    with url when is_binary(url) <- Keyword.get(opts, :site_url),
         key when is_binary(key) <- Keyword.get(opts, :deploy_key),
         {:ok, _accepted} <- trigger_message(url, key, opts) do
      Wait.sleep(Keyword.get(opts, :loopback_settle_ms, 3_000))
    end

    :ok
  rescue
    # Optional by construction: never fail the step for it (a cassette
    # recorded without this request raises on the miss).
    error ->
      Logger.debug("[Widget] loopback trigger skipped: #{inspect(error)}")
      :ok
  end

  defp blank do
    %{state: nil, install: nil, presence: nil, proof: nil, proven_at: nil, reason: nil}
  end

  defp fetch(url) do
    req_opts = [method: :get, url: url, retry: false, receive_timeout: 15_000] ++ plug_opt()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: to_string(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
