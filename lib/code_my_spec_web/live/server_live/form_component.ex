defmodule CodeMySpecWeb.ServerLive.FormComponent do
  @moduledoc """
  Edit what a linked server is for.

  One field, and it is the only one on this record that is Sam's answer rather
  than the provider's. Name, size, address and status are all read from Hetzner
  every time they are shown; what a box is *for* is the thing nothing but he
  can say.

  ## Why the list is a select with an escape hatch

  `prod` and `uat` are what setup builds today, so they should be one click
  rather than something to spell. They are seeded suggestions, not a closed
  set: choosing **Other…** reveals a text field, and the stored value is a
  plain string.

  That distinction is the whole design. `provisioning_environments` exists
  because `["prod", "uat"]` had been a literal repeated through seven places in
  `Provisioning.Steps`; an enum here would put it straight back, and could not
  hold `qa-story-812` at all.
  """

  use CodeMySpecWeb, :live_component

  alias CodeMySpec.Servers

  # Not a value anyone would type, and never stored — it is the select's
  # "none of these" branch, which is a question rather than an answer.
  @other "__other__"

  @impl true
  def update(%{server: server, environments: environments} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:other, @other)
     |> assign(:environments, environments)
     |> assign(:custom?, custom?(server.environment, environments))
     |> assign_form(Servers.change_server(server))}
  end

  @impl true
  def handle_event("validate", %{"server" => params}, socket) do
    custom? = params["environment"] == @other or (socket.assigns.custom? and pending?(params))

    changeset =
      socket.assigns.server
      |> Servers.change_server(resolve(params, custom?))
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign(:custom?, custom?) |> assign_form(changeset)}
  end

  def handle_event("save", %{"server" => params}, socket) do
    case Servers.update_server(socket.assigns.server, resolve(params, socket.assigns.custom?)) do
      {:ok, server} ->
        notify_parent(server)

        {:noreply,
         socket
         |> put_flash(:info, "Saved")
         |> push_patch(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # Once the text field is showing, it is the answer — the select still reads
  # "Other…", and taking that literally would store the sentinel.
  defp resolve(%{"environment" => @other} = params, _custom?),
    do: Map.put(params, "environment", params["custom"] || "")

  defp resolve(params, true), do: Map.put(params, "environment", params["custom"] || "")
  defp resolve(params, _custom?), do: params

  defp pending?(params), do: params["environment"] in [@other, nil]

  # A label already saved that is not one of the suggestions has to open in the
  # text field, or editing anything else on the form would quietly replace it
  # with whichever option happened to be selected.
  defp custom?(nil, _environments), do: false
  defp custom?(environment, environments), do: environment not in environments

  defp notify_parent(server), do: send(self(), {:server_saved, server})

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "server"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        Edit {@server.name}
        <:subtitle>
          What this box is for. Two servers running the same image are told apart
          only by this — it is what decides whether real mail goes out from one.
        </:subtitle>
      </.header>

      <.form
        for={@form}
        id="server-form"
        data-test="server-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <div class="fieldset mb-2">
          <label>
            <span class="label mb-1">Environment</span>
          </label>
          <select
            name="server[environment]"
            data-test="environment-select"
            class="select select-bordered w-full"
          >
            <option value="" selected={is_nil(@server.environment) and not @custom?}>
              Not set
            </option>
            <option
              :for={known <- @environments}
              value={known}
              selected={not @custom? and known == @server.environment}
            >
              {known}
            </option>
            <option value={@other} selected={@custom?}>Other…</option>
          </select>
        </div>

        <div :if={@custom?} class="fieldset mb-2">
          <label>
            <span class="label mb-1">Name it</span>
          </label>
          <input
            type="text"
            name="server[custom]"
            value={@form[:environment].value}
            data-test="environment-custom"
            placeholder="qa-story-812"
            class="input input-bordered w-full"
          />
          <p class="text-xs opacity-60 mt-1">
            Anything you like — prod and uat are only what setup builds today.
          </p>
        </div>

        <div class="modal-action">
          <.link patch={@return_to} data-test="cancel-edit" class="btn">Cancel</.link>
          <button type="submit" data-test="save-server" class="btn btn-primary">Save</button>
        </div>
      </.form>
    </div>
    """
  end
end
