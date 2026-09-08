defmodule CodeMySpec.Analytics do
  @moduledoc """
  Domain event dispatcher for activation/onboarding analytics.

  Events flow through this module and fan out to:

    * `:telemetry` handlers — including the GA Measurement Protocol
      worker in production and any handlers attached by tests.
    * Test subscribers attached via `attach_test_subscriber/1`, which
      receive `{:analytics_event, name, payload}` messages.

  Conversion events (`:sign_up`, `:registration_email_sent`,
  `:first_cli_connect`) are dispatched server-side and delivered to
  GA4 via the Measurement Protocol. Browser behavior events
  (page_view, install_command_copy, view_register_page,
  onboarding_panel_viewed, install_step_copied) are handled by gtag.js
  in the browser — those events do not flow through this module.

  ## Usage

      Analytics.dispatch(:sign_up, %{user_id: user.id})

      # In tests:
      :ok = Analytics.attach_test_subscriber(self())
      Analytics.dispatch(:something, %{})
      assert_receive {:analytics_event, :something, %{}}
  """

  @type event_name :: atom()
  @type payload :: map()

  @telemetry_event [:code_my_spec, :analytics, :event]

  @doc """
  Dispatches an activation event. Returns `:ok` synchronously; any
  delivery work (GA, etc.) is handled by attached telemetry handlers
  and is fire-and-forget.

  `origin` distinguishes browser-originated events (the LV also pushes
  these to the client for gtag forwarding — server-side GA delivery is
  skipped to avoid double-counting) from server-originated events
  (delivered to GA via Measurement Protocol).
  """
  @spec dispatch(event_name(), payload(), :browser | :server) :: :ok
  def dispatch(event_name, payload \\ %{}, origin \\ :server)
      when is_atom(event_name) and is_map(payload) and origin in [:browser, :server] do
    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{event: event_name, payload: payload, origin: origin}
    )

    :ok
  end

  @doc """
  Registers `pid` to receive every dispatched event as a message of
  the form `{:analytics_event, name, payload}`. Handler is automatically
  detached when the pid dies.
  """
  @spec attach_test_subscriber(pid()) :: :ok
  def attach_test_subscriber(pid) when is_pid(pid) do
    :telemetry.attach(
      handler_id(pid),
      @telemetry_event,
      &__MODULE__.__test_subscriber_handler__/4,
      pid
    )

    Process.monitor(pid) |> tap(fn _ -> :ok end)
    :ok
  end

  @doc """
  Removes the test subscriber for `pid`.
  """
  @spec detach_test_subscriber(pid()) :: :ok
  def detach_test_subscriber(pid) when is_pid(pid) do
    :telemetry.detach(handler_id(pid))
    :ok
  end

  @doc "The `:telemetry.attach/4` handler `attach_test_subscriber/1` registers — must be public, `:telemetry` calls it from outside this module."
  def __test_subscriber_handler__(@telemetry_event, _measurements, metadata, pid) do
    if Process.alive?(pid) do
      send(pid, {:analytics_event, metadata.event, metadata.payload})
    end
  end

  @doc "The event name test subscribers attach to."
  def telemetry_event, do: @telemetry_event

  defp handler_id(pid) do
    {:code_my_spec_analytics_test_subscriber, :erlang.pid_to_list(pid)}
  end
end
