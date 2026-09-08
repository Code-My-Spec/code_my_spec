defmodule CodeMySpec.Provisioning.Widget do
  @moduledoc """
  Installs the support widget on the deployed site and proves it works.

  Installation runs the existing generator (`cms_gen.support_widget`) through
  `CodeMySpec.Environments.cmd/4`. This module does not reimplement the widget.

  ## The generator has to be one the project actually ships

  This step ran `client_utils.gen.chat_widget` long after that task was
  deprecated and dropped from the published `client_utils` package, so every
  run exited 1 on "the task could not be found". The widget the scaffolder
  installs (`CodeMySpec.AgentTasks.CodeGeneration`) and the widget this step
  proves have to be the same generator, or provisioning verifies something no
  new project has.

  It then happened a second time. `cms_gen.feedback_widget` carries its own
  deprecation notice pointing at `cms_gen.support_widget`, and the two are not
  interchangeable: the feedback widget talks OAuth/REST and requires
  `cms_gen.integrations` to have run first, while this step's stated
  precondition is a *deploy key*, which only the support widget uses. Every
  criterion in story 973 that exercises the CodeMySpec side goes through
  `WidgetSocket` and `ConversationChannel` — the support widget's transport.
  So the story had already chosen; the step was naming the other one.

  ## Presence is a published contract, not a guessed selector

  `verify_present/2` looked for `data-cms-widget` and `widget.js`, neither of
  which any template has ever emitted — so a correct install reported
  `present: false` and the step could not pass on a real application. Rather
  than chase the widget's DaisyUI classes from out here, the generated widget
  publishes stable markers for exactly this purpose (`data-cms-widget`,
  `data-cms-widget-toggle`, `data-cms-widget-state`). An external prober is a
  legitimate consumer; giving it a contract is cheaper than reverse-engineering
  the markup on every restyle.

  ## Anonymous by design

  The widget accepts visitors who never signed up, because that is where the
  most useful feedback comes from — someone who bounced off the product has
  more to say about it than someone who stayed, and asking them to register
  first loses exactly that (criterion 8057). `install/3` therefore does not
  take an auth requirement; there is no knob here to make it members-only,
  because adding one invites turning it on.

  ## Degrading quietly is the widget's job; proving it is this module's

  When the backend is unreachable the page must still render and still be
  usable, with the widget itself showing unavailable (criterion 8043). A
  feedback widget that white-screens the site is worse than no widget: it
  breaks the thing it was added to improve.

  The degradation behaviour lives in the generated JS. `probe_degraded/2`
  verifies it from outside, because a claim about resilience that is never
  exercised is just a comment.

  ## Done means a message arrived

  Not that the script tag is present, not that the generator ran — criterion
  8044 wants a real message that travelled from the deployed site into
  CodeMySpec, with its origin recorded. Markup can be right while the socket
  is misconfigured, the credential is wrong, or CORS blocks the connection;
  every one of those produces a page that looks correct and a widget nobody
  can send through.
  """

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Users.Scope

  @generator "cms_gen.support_widget"

  # What the generated widget publishes for an outside prober. Kept here as
  # named defaults so the contract is one place rather than three string
  # literals scattered through the probes.
  @present_marker "data-cms-widget"
  @toggle_marker "data-cms-widget-toggle"

  @doc """
  The markers a prober looks for, as data.

  They are a published contract — the moduledoc above says so — and a contract
  nobody can read is one every consumer copies. The spex fakes serve a page for
  the deploy and widget probes to fetch, and they had these two strings written
  out again: change the contract and the fake keeps serving the old markers, so
  the criteria pass while the real widget stops being found.
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
    # :mix_bin so a test can point at a stub without mutating PATH, which in
    # an async suite leaks into whatever else is running.
    mix = Keyword.get(opts, :mix_bin, "mix")

    # Mix reports a missing task on stderr. Without :stderr_to_stdout the
    # failure arrived as "exit 1:" and nothing, which reads like the generator
    # refusing rather than never being found.
    #
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

  # The generator, but only once.
  #
  # `cms_gen.support_widget` calls `Mix.Phoenix.prompt_for_conflicts/1`, which
  # asks before overwriting files it has already written. So the *second* run of
  # a step designed to be re-runnable stopped and waited for an answer nobody
  # was there to give — not slow, infinite: a drill sat on it for twenty minutes
  # having spent one second of CPU, and in a real run it would hold the whole
  # sequence open forever while reporting nothing.
  #
  # Skipping is also the honest answer rather than merely the safe one. This
  # step's claim is that the widget is installed, present and proven; when the
  # files are already there the install is done, and the two checks after it are
  # what actually establish the rest. Answering the prompt instead — however it
  # were answered — would either overwrite a file the operator may have edited
  # or decline and carry on, which is this, with a prompt.
  # Found from the tree, not from the project row.
  #
  # The first version derived the path from `project.module_name`, which is the
  # name of the CodeMySpec project ("spex drill") and not of the application in
  # the checkout (`cms_drill_app`). So it looked for
  # `lib/spex_drill_web/live/support_widget_live.ex`, never found it, and ran
  # the generator into the prompt anyway. The application names itself in its
  # own `lib/`, and that is the thing being asked about.
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

  Both matter. Present-but-not-openable is the shape a broken bundle takes —
  the script tag renders, the mount point never initialises, and the page
  looks correct to anyone reading the HTML.
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

  Passes when the page still answers 200, still renders its own content, and
  does not claim a widget connection it does not have. A page that 500s breaks
  the site the widget was added to improve; a page reporting the widget as
  connected while the backend is gone swallows feedback, and the visitor
  believes they were heard (criterion 8043).

  ## What an HTTP probe can and cannot see

  This asked whether the widget "reports itself unavailable", which over HTTP
  it never can. The served document is a dead render: no socket has been
  attempted yet, so the widget's state marker reads the same whether
  CodeMySpec is reachable or not. The old check therefore passed on any page
  carrying the marker and proved nothing about degradation.

  What is observable from outside is the negative — the page renders, and it
  does not assert `connected`. That is the claim this makes. Watching the
  widget actually fail over (connect, fail, mark itself unavailable, throw
  nothing at the visitor) needs a browser, and belongs in the generated
  application's own tests rather than in a probe that has to work against a
  customer's production site from here.
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

        # "absent" fails too. A page with no widget on it degrades perfectly
        # and proves nothing, so a site where the install had silently done
        # nothing was reported as resilient.
        if usable and state not in ["connected", "absent"],
          do: {:ok, probe},
          else: {:error, probe}

      {:ok, %{status: status}} ->
        {:error, %{page_status: status, page_usable: false, widget_state: "unknown"}}

      {:error, reason} ->
        {:error, %{page_status: inspect(reason), page_usable: false, widget_state: "unknown"}}
    end
  end

  # The value the page published, rather than whether one particular value was
  # present. "absent" and "unavailable" are different answers and the caller
  # should be able to tell them apart — a page carrying no widget at all was
  # being reported as degrading correctly.
  defp served_widget_state(body) do
    case Regex.run(~r/data-cms-widget-state="([^"]*)"/, body) do
      [_, state] -> state
      nil -> "absent"
    end
  end

  @doc """
  Whether a real message has arrived from the deployed site.

  `lookup` is given the scope and returns the messages CodeMySpec has received
  for the project. A message counts only when its origin is the deployed site
  — one sent from a local dev server proves the backend works but says nothing
  about the widget actually being installed where visitors are.
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
  As with the deploy and content steps, there is no field that says "done"
  independently of the proof.

  Each stage keeps what the ones before it learned. Written as a single `with`,
  every failure clause rebuilt the result from nothing, so a widget that was
  installed and verified present and then had no message to show reported
  `presence: nil` — and criterion 8040, which is only about presence, had
  nothing to read. The one thing the step had proved was the thing it threw
  away.
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

  The proof this step wants is a message *from the deployed site*, and until
  now only a visitor's browser could produce one — so a working install sat
  unproven until somebody happened to use it. The generated application exposes
  `POST /_cms/verify/widget`, which drives its own Slipstream client with its
  own deploy key over its own socket, so the thing being proven is the thing
  that runs.

  What it does not prove is the browser half: that the bundle mounts and that a
  real visitor's origin passes CORS. `verify_present/2` covers the markup being
  served and openable; between them the gap is narrow, and the resource records
  `via=loopback` so a later message from an actual visitor can be told apart
  rather than conflated with this.

  Failure is not fatal here. An application generated before this endpoint
  existed answers 404, and one built without the widget answers 501 — neither
  means the widget is broken, and the poll that follows is the real check.
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

    # Ask before looking. The message this step wants can only come from the
    # deployed application, so waiting for one to appear by itself meant waiting
    # on a visitor — and reporting a working widget unproven in the meantime.
    #
    # Deliberately unchecked: an application generated before the endpoint
    # existed answers 404 and one without the widget answers 501, and neither is
    # evidence about the widget. What follows is the check either way, and a
    # message that arrives from a real visitor proves it just as well.
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

  # The trigger, and the wait for the message to make the round trip.
  #
  # `/_cms/verify/widget` answers 202 as soon as it has handed the message to
  # its client, because the send is asynchronous — the proof is that the message
  # turns up on our side, not that the request returned. So the poll that
  # follows needs something to find, and a check that ran immediately would
  # report "no message" against one still in flight.
  defp ask_the_site_to_speak(opts) do
    with url when is_binary(url) <- Keyword.get(opts, :site_url),
         key when is_binary(key) <- Keyword.get(opts, :deploy_key),
         {:ok, _accepted} <- trigger_message(url, key, opts) do
      Wait.sleep(Keyword.get(opts, :loopback_settle_ms, 3_000))
    end

    :ok
  rescue
    # Nothing this call can do is worth failing the step for, including
    # raising. A cassette recorded before the endpoint existed has no entry for
    # this request and a replay raises on the miss — which would turn every
    # previously-recorded widget criterion red for a request that is optional by
    # construction. The message lookup below is the actual check.
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
