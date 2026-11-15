defmodule WriteApi.DashboardLive do
  @moduledoc """
  The dashboard at `/dashboard`. `WriteApi.Dashboard.Auth` mounts it with `:current_user`
  (or nil), `:sealed_session_token` and `:auth_error`; a signed-out visit renders the signed-out view,
  never a redirect. Signing in and out happen in the browser (`GoogleSignIn` and `SignOut` hooks,
  against the JSON endpoints); the hooks report a failed sign-in with `"sign_in_failed"`.

  Signed in, it lists the user's links newest first in a stream (`links-<code>` DOM ids), one
  page at a time (`"load_more"`, `"retry"`). The cursor of the next page lives only in the
  socket. Every paging event first calls `ensure_session/1`, so a session that expired while
  the page stayed open stops being served.

  "+ Novo link" opens a modal (`:modal` is `nil`, `:form` or `{:created, link}`). `"create"` calls
  `ensure_session/1`, then `WriteApi.Shortener.create/2` for the signed-in user and, on success,
  puts the link at the top of the stream and turns the modal into a confirmation; on failure the
  modal stays open with the typed values and the error next to its field. The session token is
  kept sealed in the socket and only unsealed inside `ensure_session/1`, never rendered or sent
  to the browser.
  """

  use Phoenix.LiveView

  import WriteApi.DashboardComponents

  alias ShortenerCore.{User, UserStore}
  alias WriteApi.{Config, Links, Session, Shortener}
  alias WriteApi.Dashboard.Auth

  @form_fields ~w(url alias ttl_seconds)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:sign_in_error, nil)
      |> assign(:links_status, :ok)
      |> assign(:next_cursor, nil)
      |> assign(:loaded_count, 0)
      |> reset_modal()
      |> stream_configure(:links, dom_id: &"links-#{&1.code}")
      |> stream(:links, [])

    {:ok, if(socket.assigns.current_user, do: load_page(socket), else: socket)}
  end

  @impl true
  def handle_event("sign_in_failed", %{"code" => code}, socket) when is_binary(code) do
    {:noreply, assign(socket, :sign_in_error, code)}
  end

  def handle_event("sign_in_failed", _params, socket) do
    {:noreply, assign(socket, :sign_in_error, "unknown")}
  end

  def handle_event("open_modal", _params, %{assigns: %{modal: :form}} = socket),
    do: {:noreply, socket}

  def handle_event("open_modal", _params, socket),
    do: {:noreply, socket |> reset_modal() |> assign(:modal, :form)}

  def handle_event("close_modal", _params, socket), do: {:noreply, reset_modal(socket)}

  def handle_event("set_mode", %{"mode" => mode}, %{assigns: %{modal: :form}} = socket)
      when mode in ["generate", "alias"] do
    {:noreply,
     socket
     |> assign(:mode, mode)
     |> assign(:form_error, Map.delete(socket.assigns.form_error, :alias))}
  end

  def handle_event("form_change", params, %{assigns: %{modal: :form}} = socket) do
    # An error goes away when its field is edited again.
    edited = for field <- List.wrap(params["_target"]), do: field_key(field)

    {:noreply,
     socket
     |> assign(:form, typed_values(params, socket.assigns.form))
     |> assign(:form_error, Map.drop(socket.assigns.form_error, edited))}
  end

  # Stale form events (the modal is already closed or confirmed) change nothing.
  def handle_event(event, _params, socket) when event in ["set_mode", "form_change"],
    do: {:noreply, socket}

  def handle_event("create", params, socket) do
    # A write: re-verify the session first. A user store failure here redirects like a signed
    # out session, on purpose (nothing is written without a verified user).
    case ensure_session(socket) do
      {:ok, socket} -> {:noreply, create_link(socket, params)}
      {:signed_out, socket} -> {:noreply, socket}
    end
  end

  def handle_event(event, _params, socket) when event in ["load_more", "retry"] do
    case ensure_session(socket) do
      {:ok, socket} -> {:noreply, load_if_due(event, socket)}
      {:signed_out, socket} -> {:noreply, socket}
    end
  end

  # Only the open form creates; a repeated submit after success (or a stale one) does nothing.
  defp create_link(%{assigns: %{modal: :form}} = socket, params) do
    %{current_user: user, mode: mode} = socket.assigns
    form = typed_values(params, default_form())
    url = String.trim(form["url"])

    case Shortener.create(api_params(form, url, mode), owner_id: user.id) do
      {:ok, link} ->
        socket
        |> stream_insert(:links, link_row(link, url), at: 0)
        |> assign(:loaded_count, socket.assigns.loaded_count + 1)
        |> assign(:form, default_form())
        |> assign(:form_error, %{})
        |> assign(:modal, {:created, link})

      {:error, reason} ->
        {field, message} = create_error(reason)

        socket
        |> assign(:form, form)
        |> assign(:form_error, %{field => message})
    end
  end

  defp create_link(socket, _params), do: socket

  # The body of `POST /urls`: the alias only in alias mode, and then always, even when blank (the
  # API rejects it as :invalid_alias rather than silently generating a code); the expiry only
  # when one is chosen.
  defp api_params(form, url, mode) do
    %{"url" => url}
    |> put_alias(mode, String.trim(form["alias"]))
    |> put_unless_blank("ttl_seconds", ttl_param(String.trim(form["ttl_seconds"])))
  end

  defp put_alias(params, "alias", custom_alias), do: Map.put(params, "custom_alias", custom_alias)
  defp put_alias(params, _generate, _custom_alias), do: params

  defp put_unless_blank(map, _key, ""), do: map
  defp put_unless_blank(map, key, value), do: Map.put(map, key, value)

  # An integer when it is one; anything else goes through and is rejected as :invalid_ttl.
  defp ttl_param(text) do
    case Integer.parse(text) do
      {seconds, ""} -> seconds
      _ -> text
    end
  end

  # The same row shape the list uses (`WriteApi.LinkView.to_map/2`), from the create result.
  defp link_row(link, url) do
    %{
      code: link.code,
      short_url: link.short_url,
      long_url: url,
      is_custom_alias: link.is_custom_alias,
      created_at: link.created_at,
      expires_at: link.expires_at,
      status: "active"
    }
  end

  defp reset_modal(socket) do
    socket
    |> assign(:modal, nil)
    |> assign(:mode, "generate")
    |> assign(:form, default_form())
    |> assign(:form_error, %{})
  end

  defp default_form, do: %{"url" => "", "alias" => "", "ttl_seconds" => to_string(default_ttl())}

  # Only the known fields, only strings: whatever else the client sends is dropped. A field the
  # page did not send (the alias input is absent in generate mode) keeps its value from `base`.
  defp typed_values(params, base) do
    Map.new(@form_fields, fn field ->
      case params[field] do
        value when is_binary(value) -> {field, value}
        _ -> {field, base[field]}
      end
    end)
  end

  defp field_key("ttl_seconds"), do: :ttl_seconds
  defp field_key("alias"), do: :alias
  defp field_key("url"), do: :url
  defp field_key(_other), do: nil

  # The host (and a non-default port) of the redirect service, which the short links use.
  defp base_host do
    uri = URI.parse(Application.fetch_env!(:write_api, :base_url))

    if uri.port in [nil, URI.default_port(uri.scheme)],
      do: uri.host,
      else: "#{uri.host}:#{uri.port}"
  end

  # "load_more" needs a next page; "retry" needs a failed load. Anything else is stale.
  defp load_if_due("load_more", %{assigns: %{next_cursor: cursor}} = socket)
       when is_binary(cursor),
       do: load_page(socket)

  defp load_if_due("retry", %{assigns: %{links_status: :error}} = socket), do: load_page(socket)
  defp load_if_due(_event, socket), do: socket

  # Fetches the page after `next_cursor` (the first when nil) and appends it. A failure keeps
  # the links already shown and the cursor, so a retry asks for the same page again.
  defp load_page(socket) do
    %{current_user: user, next_cursor: cursor} = socket.assigns
    query = if cursor, do: %{"cursor" => cursor}, else: %{}

    case Links.page(user.id, query) do
      {:ok, %{links: links, next_cursor: next_cursor}} ->
        socket
        |> stream(:links, links)
        |> assign(:links_status, :ok)
        |> assign(:next_cursor, next_cursor)
        |> assign(:loaded_count, socket.assigns.loaded_count + length(links))

      {:error, _reason} ->
        assign(socket, :links_status, :error)
    end
  end

  # Re-verifies the session token at the current time and that its user still exists;
  # otherwise sends the browser to /dashboard, which mounts signed out. The token is only
  # ever unsealed here, never assigned or rendered.
  defp ensure_session(socket) do
    with token when is_binary(token) <- Auth.unseal(socket.assigns.sealed_session_token),
         {:ok, user_id} <- Session.verify_token(token, DateTime.utc_now()),
         %User{id: ^user_id} <- socket.assigns.current_user,
         {:ok, %User{}} <- UserStore.get(user_id) do
      {:ok, socket}
    else
      _ -> {:signed_out, redirect(socket, to: "/dashboard")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main :if={@current_user} data-test="signed-in">
      <.app_header user={@current_user} />
      <section class="mx-auto flex max-w-3xl flex-col gap-4 p-4">
        <.list_header
          count={@loaded_count}
          more={@next_cursor != nil}
          show_count={@links_status == :ok or @loaded_count > 0}
        />
        <.empty_state :if={@links_status == :ok and @loaded_count == 0} />
        <.link_list links={@streams.links} next_cursor={@next_cursor} status={@links_status} />
      </section>
      <.new_link_modal
        :if={@modal == :form}
        form={@form}
        mode={@mode}
        errors={@form_error}
        base_host={base_host()}
      />
      <.link_created :if={match?({:created, _}, @modal)} link={elem(@modal, 1)} />
    </main>
    <main :if={!@current_user} data-test="signed-out" class="flex min-h-screen items-center justify-center p-4">
      <.sign_in_card
        client_id={Config.google_client_id()}
        error={@sign_in_error}
        auth_error={@auth_error}
      />
    </main>
    """
  end
end
