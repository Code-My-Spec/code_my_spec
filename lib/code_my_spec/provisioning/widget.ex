defmodule CodeMySpec.Provisioning.Widget do
  @moduledoc """
  Installs the feedback widget on the deployed site and proves it works.

  Installation runs the existing generator (`client_utils.gen.chat_widget`)
  through `CodeMySpec.Environments.cmd/4` and wires the project's credential.
  This module does not reimplement the widget.

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

  alias CodeMySpec.Environments
  alias CodeMySpec.Users.Scope

  @generator "client_utils.gen.chat_widget"

  @type result :: %{
          state: :proven | :install_failed | :absent | :not_proven,
          install: map() | nil,
          presence: map() | nil,
          proof: map() | nil,
          proven_at: DateTime.t() | nil,
          reason: String.t() | nil
        }

  @doc """
  Run the widget generator against the project, wiring its credential.

  Returns the generator's output so a failure can be reported with what it
  actually said rather than "install failed".
  """
  @spec install(Environments.Environment.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def install(env, deploy_key, opts \\ []) when is_binary(deploy_key) do
    # `mix <task>`, not `mix run <task>`. `mix run` takes a *file* — given a
    # task name it answers "No such file: client_utils.gen.chat_widget" and
    # exits, so the generator has never once run. The step reported "Widget
    # generator failed (exit 1)" with an empty body, which reads like the
    # generator refusing rather than never being invoked.
    args = [@generator, "--deploy-key", deploy_key] ++ Keyword.get(opts, :extra_args, [])
    # :mix_bin so a test can point at a stub without mutating PATH, which in
    # an async suite leaks into whatever else is running.
    mix = Keyword.get(opts, :mix_bin, "mix")

    case Environments.cmd(env, mix, args) do
      {output, 0} -> {:ok, %{output: output}}
      {output, status} -> {:error, "Widget generator failed (exit #{status}): #{output}"}
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
    marker = Keyword.get(opts, :marker, "data-cms-widget")

    case fetch.(site_url) do
      {:ok, %{status: 200, body: body}} ->
        present = String.contains?(body, marker)
        openable = present and String.contains?(body, Keyword.get(opts, :bundle_marker, "widget.js"))

        presence = %{status: 200, present: present, openable: openable}

        case openable do
          true -> {:ok, presence}
          false -> {:error, presence}
        end

      {:ok, %{status: status}} ->
        {:error, %{status: status, present: false, openable: false}}

      {:error, reason} ->
        {:error, %{status: inspect(reason), present: false, openable: false}}
    end
  end

  @doc """
  Verify the page survives an unreachable backend.

  Passes only when the page still answers 200 AND remains usable AND the
  widget reports itself unavailable. A page that 500s, or one where the widget
  silently pretends to work, both fail — the first breaks the site, the second
  swallows feedback (criterion 8043).
  """
  @spec probe_degraded(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def probe_degraded(site_url, opts \\ []) do
    fetch = Keyword.get(opts, :fetch_degraded, Keyword.get(opts, :fetch, &fetch/1))

    case fetch.(site_url) do
      {:ok, %{status: 200, body: body}} ->
        usable = not String.contains?(body, Keyword.get(opts, :broken_marker, "Application error"))
        unavailable = String.contains?(body, Keyword.get(opts, :unavailable_marker, "widget-unavailable"))

        probe = %{page_status: 200, page_usable: usable, widget_state: widget_state(unavailable)}

        case usable and unavailable do
          true -> {:ok, probe}
          false -> {:error, probe}
        end

      {:ok, %{status: status}} ->
        {:error, %{page_status: status, page_usable: false, widget_state: "unknown"}}

      {:error, reason} ->
        {:error, %{page_status: inspect(reason), page_usable: false, widget_state: "unknown"}}
    end
  end

  defp widget_state(true), do: "unavailable"
  defp widget_state(false), do: "unknown"

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
  """
  @spec run(Scope.t(), Environments.Environment.t(), keyword()) :: result()
  def run(%Scope{} = scope, env, opts \\ []) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    site_url = Keyword.fetch!(opts, :site_url)
    deploy_key = Keyword.fetch!(opts, :deploy_key)

    with {:ok, install} <- install(env, deploy_key, opts),
         {:ok, presence} <- verify_present(site_url, opts),
         {:ok, proof} <- message_proof(scope, opts) do
      %{
        state: :proven,
        install: install,
        presence: presence,
        proof: proof,
        proven_at: now.(),
        reason: nil
      }
    else
      {:error, reason} when is_binary(reason) ->
        %{state: :install_failed, install: nil, presence: nil, proof: nil, proven_at: nil, reason: reason}

      {:error, :no_message} ->
        %{
          state: :not_proven,
          install: nil,
          presence: nil,
          proof: nil,
          proven_at: nil,
          reason:
            "The widget is installed and openable, but no message has travelled from the " <>
              "deployed site yet. Markup can be right while the socket, credential or CORS is not."
        }

      {:error, %{present: _} = presence} ->
        %{
          state: :absent,
          install: nil,
          presence: presence,
          proof: nil,
          proven_at: nil,
          reason: "The widget is not usable on #{site_url} (#{inspect(presence)})."
        }
    end
  end

  defp fetch(url) do
    req_opts = [method: :get, url: url, retry: false, receive_timeout: 15_000] ++ plug_opt()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: to_string(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
