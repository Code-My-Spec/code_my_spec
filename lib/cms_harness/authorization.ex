defmodule CmsHarness.Authorization do
  @moduledoc """
  Registers this harness, waits for device approval, and keeps its token fresh.
  Authorization runs after boot so waiting for a person never blocks hooks.
  Denial, expiry, and revoked credentials stop the flow until explicitly retried.
  """
  use GenServer
  require Logger

  alias CmsHarness.{Config, Device}
  alias CodeMySpec.Auth.HarnessOAuth

  def start_link(opts \\ []) do
    if Keyword.get(opts, :enabled, true),
      do: GenServer.start_link(__MODULE__, opts, name: __MODULE__),
      else: :ignore
  end

  @doc "Start a new device authorization attempt after denial, expiry, or revocation."
  def retry, do: GenServer.cast(__MODULE__, :retry)

  @doc "Public authorization progress, without device codes or tokens."
  def status do
    GenServer.call(__MODULE__, :status, 1_000)
  catch
    :exit, _ -> %{phase: :unavailable}
  end

  @impl true
  def handle_call(:status, _from, state) do
    public =
      case state.grant do
        nil ->
          %{phase: state.phase}

        grant ->
          %{phase: :pending, verification_uri: grant.verification_uri, user_code: grant.user_code}
      end

    {:reply, public, state}
  end

  @impl true
  def init(opts) do
    state = %{
      server: Keyword.get(opts, :server_url, Config.server_url()),
      opts: Keyword.get(opts, :oauth_opts, Application.get_env(:code_my_spec, HarnessOAuth, [])),
      check_interval_seconds: Keyword.get(opts, :check_interval_seconds, 60),
      grant: nil,
      timer: nil,
      announced: false,
      phase: :starting
    }

    {:ok, state, {:continue, :check}}
  end

  @impl true
  def handle_continue(:check, state), do: check(state)

  @impl true
  def handle_cast(:retry, state) do
    cancel(state.timer)
    begin_authorization(%{state | grant: nil, timer: nil, announced: false, phase: :starting})
  end

  @impl true
  def handle_info({:timeout, ref, action}, %{timer: ref} = state) do
    state = %{state | timer: nil}

    case action do
      :check -> check(state)
      :begin -> begin_authorization(state)
      :poll -> poll(state)
    end
  end

  def handle_info({:timeout, _ref, _action}, state), do: {:noreply, state}

  defp check(state) do
    case HarnessOAuth.access_token(state.server, state.opts) do
      {:ok, token} -> authorized(state, token)
      {:error, :no_credential} -> begin_authorization(state)
      {:error, :unreachable} -> schedule(state, :check, 30)
      {:error, reason} -> refused(state, reason)
    end
  end

  defp begin_authorization(state) do
    case HarnessOAuth.begin_authorization(state.server, Device.ensure_id(), state.opts) do
      {:ok, grant} ->
        Logger.notice(
          "[CmsHarness] Connect this harness: visit #{grant.verification_uri} and enter #{grant.user_code}"
        )

        schedule(%{state | grant: grant}, :poll, grant.interval)

      {:error, :unreachable} ->
        schedule(state, :begin, 30)

      {:error, reason} ->
        refused(state, reason)
    end
  end

  defp poll(state) do
    case HarnessOAuth.poll(state.server, state.grant, state.opts) do
      {:ok, token} ->
        authorized(%{state | grant: nil}, token)

      {:error, :authorization_pending} ->
        schedule(state, :poll, state.grant.interval)

      {:error, :slow_down} ->
        grant = %{state.grant | interval: state.grant.interval + 5}
        schedule(%{state | grant: grant}, :poll, grant.interval)

      {:error, :unreachable} ->
        grant = %{state.grant | interval: state.grant.interval * 2}
        schedule(%{state | grant: grant}, :poll, grant.interval)

      {:error, reason} ->
        refused(state, reason)
    end
  end

  defp authorized(state, token) do
    announced = state.announced or match?({:ok, _}, Device.announce(%{}, token))

    schedule(
      %{state | announced: announced, phase: :authorized},
      :check,
      state.check_interval_seconds
    )
  end

  defp refused(state, reason) do
    Logger.warning(
      "[CmsHarness] Device authorization stopped: #{inspect(reason)}. Retry authorization to connect."
    )

    {:noreply, %{state | grant: nil, timer: nil, phase: :stopped}}
  end

  defp schedule(state, action, seconds) do
    {:noreply, %{state | timer: :erlang.start_timer(seconds * 1000, self(), action)}}
  end

  defp cancel(nil), do: :ok
  defp cancel(ref), do: :erlang.cancel_timer(ref)
end
