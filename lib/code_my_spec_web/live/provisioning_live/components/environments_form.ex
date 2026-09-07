defmodule CodeMySpecWeb.ProvisioningLive.Components.EnvironmentsForm do
  @moduledoc """
  The environments panel, factored out of `ProvisioningLive`'s render the
  same way `ServerLive.FormComponent` is factored out of `ServerLive.Index`
  — the form is its own module; the `<dialog>` that shows it lives on the
  page that opens it.

  All state (`@environment_rows`) and every event (`add_environment`,
  `remove_environment`) still live on `ProvisioningLive` — this is a plain
  function component, not a `LiveComponent`, because nothing here needs
  state or a lifecycle of its own.
  """

  use CodeMySpecWeb, :html

  alias Phoenix.LiveView.JS

  attr :return_to, :string, required: true
  attr :environment_rows, :list, required: true

  def environments_form(assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-bold">Environments</h3>
      <p class="opacity-70 text-sm mt-1">
        Environments never share a server — each one names the box it runs on.
      </p>

      <%!-- Turning production on is adding an environment, not ticking a box.
          There is no `prod` option on the setup form and never was — the
          steps fan out over whichever environment rows exist, which is what
          lets a project have `qa`, or one per story, without a code change. --%>
      <.form
        for={%{}}
        as={:environment}
        data-test="add-environment-form"
        phx-submit="add_environment"
        class="mt-3 flex gap-2 items-end"
      >
        <input
          type="text"
          name="environment[name]"
          data-test="environment-name"
          class="input input-bordered input-sm"
        />
        <.button type="submit" data-test="add-environment">Add environment</.button>
      </.form>

      <div
        :for={environment <- @environment_rows}
        data-test="environment"
        data-environment={environment.name}
        data-server={environment.server_name}
        data-host={environment.host}
        data-ip={environment.ip}
        class="flex items-center gap-3 mt-3"
      >
        <span>{environment.name}: {environment.server_name || "no server yet"}</span>

        <%!-- Behind a dialog rather than a bare click. This releases a real
            server and a real DNS record, and the panel's rows are one line
            apart. `data-confirm` is not an option here — the browser's own
            confirm() is invisible to the driver QA runs. --%>
        <.button
          data-test="remove-environment"
          class="btn btn-xs btn-error"
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

      <div class="modal-action">
        <.button data-test="close-environments-modal" class="btn" patch={@return_to}>
          Close
        </.button>
      </div>
    </div>
    """
  end

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
end
