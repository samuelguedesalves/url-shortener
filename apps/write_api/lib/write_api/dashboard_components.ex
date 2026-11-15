defmodule WriteApi.DashboardComponents do
  @moduledoc """
  Function components for the dashboard and every string the page shows (pt-BR).
  Pure: they render only their attrs, never the session.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias ShortenerCore.User

  @product "Encurtador"

  @doc "The sign-in message for a failure `code` from the sign-in hook; generic for unknown codes."
  @spec sign_in_error_message(term()) :: String.t()
  def sign_in_error_message("invalid_token"),
    do: "Não foi possível validar sua conta Google. Tente entrar novamente."

  def sign_in_error_message("unavailable"),
    do: "O serviço está indisponível no momento. Tente novamente em instantes."

  def sign_in_error_message("forbidden_origin"),
    do:
      "Este endereço não está autorizado a entrar. Quem administra o serviço deve conferir " <>
        "o valor de DASHBOARD_ORIGIN."

  def sign_in_error_message("script_blocked"),
    do:
      "O script de login do Google não carregou. Verifique sua conexão ou se um bloqueador " <>
        "de anúncios o bloqueou, e recarregue a página."

  def sign_in_error_message(_code), do: "Não foi possível entrar. Tente novamente."

  @doc "The signed-out card: the Google button, or why there is none."
  attr :client_id, :string,
    default: nil,
    doc: "the Google OAuth client id, nil when not configured"

  attr :error, :string, default: nil, doc: "the code of the last sign-in failure, if any"

  attr :auth_error, :atom,
    default: nil,
    doc: "`:unavailable` when the user store was down at mount"

  @spec sign_in_card(map()) :: Phoenix.LiveView.Rendered.t()
  def sign_in_card(assigns) do
    ~H"""
    <div class="card bg-base-100 w-full max-w-sm shadow-md">
      <div class="card-body items-center text-center gap-4">
        <h1 class="card-title text-2xl">{product()}</h1>
        <p class="text-base-content/70">Entre com sua conta Google para ver seus links.</p>

        <p :if={@auth_error == :unavailable} role="alert" data-test="auth-unavailable" class="alert alert-warning text-sm">
          Não foi possível verificar sua sessão agora: o serviço está indisponível. Recarregue a página em instantes.
        </p>

        <p :if={@auth_error != :unavailable and is_nil(@client_id)} data-test="sign-in-not-configured" class="alert alert-info text-sm">
          O login ainda não está configurado: defina GOOGLE_CLIENT_ID no servidor.
        </p>

        <div
          :if={@auth_error != :unavailable and @client_id}
          id="google-sign-in"
          phx-hook="GoogleSignIn"
          phx-update="ignore"
          data-client-id={@client_id}
        >
        </div>

        <p :if={@error} role="alert" data-test="sign-in-error" class="alert alert-error text-sm">
          {sign_in_error_message(@error)}
        </p>
      </div>
    </div>
    """
  end

  @doc "The header of the signed-in view: product name, the user's avatar and name, sign out."
  attr :user, User, required: true

  @spec app_header(map()) :: Phoenix.LiveView.Rendered.t()
  def app_header(assigns) do
    ~H"""
    <header class="navbar bg-base-100 shadow-sm px-4">
      <span class="flex-1 text-xl font-semibold">{product()}</span>
      <div class="flex items-center gap-3">
        <img
          :if={@user.picture_url}
          data-test="user-avatar"
          src={@user.picture_url}
          alt=""
          referrerpolicy="no-referrer"
          class="size-8 rounded-full"
        />
        <span
          :if={!@user.picture_url}
          data-test="user-avatar"
          class="bg-neutral text-neutral-content inline-flex size-8 items-center justify-center rounded-full text-sm"
        >
          {initials(@user.name)}
        </span>
        <span data-test="user-name" class="hidden sm:inline">{display_name(@user.name)}</span>
        <button id="sign-out" type="button" phx-hook="SignOut" class="btn btn-sm btn-ghost">
          Sair
        </button>
      </div>
    </header>
    """
  end

  @doc "The title with the count of loaded links (\"N+\" while more pages exist) and the new link button."
  attr :count, :integer, required: true, doc: "how many links are loaded"
  attr :more, :boolean, default: false, doc: "true while another page exists"

  attr :show_count, :boolean,
    default: true,
    doc: "false when the count is not known (load failed)"

  @spec list_header(map()) :: Phoenix.LiveView.Rendered.t()
  def list_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <h1 data-test="links-title" class="text-xl font-semibold">
        {links_title(@count, @more, @show_count)}
      </h1>
      <button type="button" phx-click="open_modal" class="btn btn-primary btn-sm">
        + Novo link
      </button>
    </div>
    """
  end

  @doc "The list title: \"Meus links (N)\", or \"Meus links (N+)\" while more pages exist."
  @spec links_title(non_neg_integer(), boolean(), boolean()) :: String.t()
  def links_title(_count, _more, false), do: "Meus links"
  def links_title(count, true, true), do: "Meus links (#{count}+)"
  def links_title(count, false, true), do: "Meus links (#{count})"

  @doc """
  The links (a LiveView stream whose items carry their DOM id), the load error with its retry
  and the "Carregar mais" button while `next_cursor` is set.
  """
  attr :links, :any, required: true, doc: "the `:links` stream"
  attr :next_cursor, :string, default: nil
  attr :status, :atom, values: [:ok, :error], default: :ok

  @spec link_list(map()) :: Phoenix.LiveView.Rendered.t()
  def link_list(assigns) do
    ~H"""
    <ul id="links" phx-update="stream" class="flex flex-col gap-2">
      <.link_row :for={{id, link} <- @links} id={id} link={link} />
    </ul>
    <.load_error :if={@status == :error} />
    <div :if={@status == :ok and @next_cursor} class="flex justify-center">
      <button type="button" phx-click="load_more" phx-disable-with="Carregando..." class="btn btn-outline btn-sm">
        Carregar mais
      </button>
    </div>
    """
  end

  @doc """
  One link, two lines: the code, whether it is an alias or generated and the copy button;
  then an arrow, the destination and the creation date. An expired link is dimmed, tagged
  "expirado", shows "destino removido" and has no copy button. The destination is plain
  (escaped) text, truncated by CSS.
  """
  attr :id, :string, required: true, doc: "the stream's DOM id"
  attr :link, :map, required: true, doc: "a link map as `WriteApi.LinkView.to_map/2` returns"

  @spec link_row(map()) :: Phoenix.LiveView.Rendered.t()
  def link_row(assigns) do
    ~H"""
    <li
      id={@id}
      data-status={@link.status}
      class={[
        "bg-base-100 flex flex-col gap-1 rounded-box px-4 py-3 shadow-sm",
        @link.status == "expired" && "opacity-60"
      ]}
    >
      <div class="flex items-center gap-2">
        <span class="font-mono font-semibold">{@link.code}</span>
        <span class="badge badge-sm badge-outline">{kind_label(@link.is_custom_alias)}</span>
        <span :if={@link.status == "expired"} class="badge badge-sm badge-warning">expirado</span>
        <button
          :if={@link.status != "expired"}
          id={"copy-#{@id}"}
          type="button"
          phx-hook="Copy"
          data-copy={@link.short_url}
          aria-label={"Copiar #{@link.short_url}"}
          class="btn btn-ghost btn-xs ml-auto"
        >
          Copiar
        </button>
      </div>
      <div class="text-base-content/70 flex items-center gap-2 text-sm">
        <span aria-hidden="true">→</span>
        <span :if={@link.long_url} title={@link.long_url} class="min-w-0 flex-1 truncate">
          {@link.long_url}
        </span>
        <span :if={!@link.long_url} class="min-w-0 flex-1 truncate italic">destino removido</span>
        <time datetime={DateTime.to_iso8601(@link.created_at)} class="shrink-0">
          {short_date(@link.created_at)}
        </time>
      </div>
    </li>
    """
  end

  @doc "The empty list: a message and a call to create the first link."
  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div data-test="empty-state" class="bg-base-100 flex flex-col items-center gap-3 rounded-box p-8 text-center shadow-sm">
      <p class="text-base-content/70">Você ainda não tem links.</p>
      <button type="button" phx-click="open_modal" class="btn btn-primary btn-sm">
        Criar meu primeiro link
      </button>
    </div>
    """
  end

  @doc "The list could not be loaded; the retry button sends `retry`."
  @spec load_error(map()) :: Phoenix.LiveView.Rendered.t()
  def load_error(assigns) do
    ~H"""
    <div data-test="links-error" role="alert" class="alert alert-warning flex items-center justify-between text-sm">
      <span>Não foi possível carregar seus links agora.</span>
      <button type="button" phx-click="retry" class="btn btn-sm">Tentar novamente</button>
    </div>
    """
  end

  # Presets of the expiry select: label and seconds, from shortest to longest.
  @ttl_presets [
    {"1 hora", 3_600},
    {"1 dia", 86_400},
    {"7 dias", 604_800},
    {"30 dias", 2_592_000},
    {"1 ano", 31_536_000},
    {"10 anos", 315_360_000}
  ]

  @doc """
  The expiry choices as `{label, seconds}`: the presets that do not exceed the configured
  maximum, the default one labelled "(padrão)".
  """
  @spec ttl_options() :: [{String.t(), pos_integer()}]
  def ttl_options do
    default = default_ttl()

    for {label, seconds} <- allowed_presets() do
      {if(seconds == default, do: label <> " (padrão)", else: label), seconds}
    end
  end

  @doc """
  The preselected expiry, in seconds: the API default when it is one of the offered presets,
  otherwise the longest offered one; nil when no preset fits under the maximum.
  """
  @spec default_ttl() :: pos_integer() | nil
  def default_ttl do
    offered = Enum.map(allowed_presets(), &elem(&1, 1))
    api_default = Application.fetch_env!(:shortener_core, :default_link_ttl)
    if api_default in offered, do: api_default, else: List.last(offered)
  end

  defp allowed_presets do
    max = Application.fetch_env!(:shortener_core, :max_link_ttl)
    Enum.filter(@ttl_presets, fn {_label, seconds} -> seconds <= max end)
  end

  @doc """
  Where a failed create shows: the form field it concerns (`:url`, `:alias`, `:ttl_seconds`) or
  `:general`, with its message.
  """
  @spec create_error(atom()) :: {:url | :alias | :ttl_seconds | :general, String.t()}
  def create_error(:alias_taken), do: {:alias, "Esse alias já está em uso"}

  def create_error(:invalid_alias),
    do:
      {:alias,
       "Alias inválido: use de 3 a 32 letras, números, hífens ou sublinhados, " <>
         "e não um nome reservado."}

  def create_error(:invalid_url),
    do: {:url, "Informe uma URL válida, começando com http:// ou https://."}

  def create_error(:invalid_ttl), do: {:ttl_seconds, "Escolha um prazo de expiração válido."}

  def create_error(_unavailable),
    do: {:general, "O serviço está temporariamente indisponível. Tente novamente em instantes."}

  @doc """
  The "Novo link" dialog: destination, the generated-or-alias selector, expiry. `errors` maps a
  field (`:url`, `:alias`, `:ttl_seconds`, `:general`) to its message; the typed values come
  back through `form` (string keys `url`, `alias`, `ttl_seconds`).
  """
  attr :form, :map, required: true
  attr :mode, :string, values: ["generate", "alias"], default: "generate"
  attr :errors, :map, default: %{}
  attr :submitting, :boolean, default: false, doc: "disables the submit button"
  attr :base_host, :string, required: true, doc: "the redirect host shown before the alias"

  @spec new_link_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def new_link_modal(assigns) do
    assigns = assign(assigns, :ttl_options, ttl_options())

    ~H"""
    <.modal title="Novo link">
      <form id="new-link-form" phx-change="form_change" phx-submit="create" class="flex flex-col gap-4">
        <p :if={@errors[:general]} role="alert" data-test="error-general" class="alert alert-warning text-sm">
          {@errors[:general]}
        </p>

        <div class="flex flex-col gap-1">
          <label for="new-link-url" class="text-sm font-medium">Destino</label>
          <input
            id="new-link-url"
            type="text"
            name="url"
            value={@form["url"]}
            placeholder="https://exemplo.com/um/endereco/bem/longo"
            autocomplete="off"
            class={["input w-full", @errors[:url] && "input-error"]}
          />
          <.field_error field={:url} errors={@errors} />
        </div>

        <div class="flex flex-col gap-2">
          <span id="new-link-mode-label" class="text-sm font-medium">Endereço curto</span>
          <div role="radiogroup" aria-labelledby="new-link-mode-label" class="join w-full">
            <button
              :for={{mode, label} <- [{"generate", "Gerar automaticamente"}, {"alias", "Escolher alias"}]}
              type="button"
              role="radio"
              aria-checked={to_string(@mode == mode)}
              phx-click="set_mode"
              phx-value-mode={mode}
              class={["btn btn-sm join-item flex-1", @mode == mode && "btn-primary"]}
            >
              {label}
            </button>
          </div>

          <p :if={@mode == "generate"} data-test="address-preview" class="text-base-content/60 font-mono text-sm">
            {@base_host}/xxxxxxx
          </p>

          <div :if={@mode == "alias"} class="flex flex-col gap-1">
            <label class={["input w-full", @errors[:alias] && "input-error"]}>
              <span data-test="alias-prefix" class="label font-mono">{@base_host}/</span>
              <input
                type="text"
                name="alias"
                value={@form["alias"]}
                placeholder="meu-alias"
                autocomplete="off"
                aria-label="Alias"
              />
            </label>
            <.field_error field={:alias} errors={@errors} />
          </div>
        </div>

        <div class="flex flex-col gap-1">
          <label for="new-link-ttl" class="text-sm font-medium">Expira em</label>
          <select
            id="new-link-ttl"
            name="ttl_seconds"
            class={["select w-full", @errors[:ttl_seconds] && "select-error"]}
          >
            <option
              :for={{label, seconds} <- @ttl_options}
              value={seconds}
              selected={to_string(seconds) == @form["ttl_seconds"]}
            >
              {label}
            </option>
          </select>
          <.field_error field={:ttl_seconds} errors={@errors} />
        </div>

        <div class="modal-action mt-0">
          <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancelar</button>
          <button type="submit" phx-disable-with="Criando..." disabled={@submitting} class="btn btn-primary">
            Criar link
          </button>
        </div>
      </form>
    </.modal>
    """
  end

  @doc "The dialog's confirmation: the full short link, a copy button and \"Fechar\"."
  attr :link, :map, required: true, doc: "the result of `WriteApi.Shortener.create/2`"

  @spec link_created(map()) :: Phoenix.LiveView.Rendered.t()
  def link_created(assigns) do
    ~H"""
    <.modal title="Link criado">
      <div data-test="link-created" class="flex flex-col gap-4">
        <div class="join w-full">
          <input
            id="created-short-url"
            type="text"
            readonly
            value={@link.short_url}
            aria-label="Link curto"
            class="input join-item w-full font-mono"
          />
          <button
            id="copy-created"
            type="button"
            phx-hook="Copy"
            data-copy={@link.short_url}
            data-copy-target="created-short-url"
            class="btn btn-primary join-item"
          >
            Copiar
          </button>
        </div>
        <div class="modal-action mt-0">
          <button type="button" phx-click="close_modal" class="btn">Fechar</button>
        </div>
      </div>
    </.modal>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  # The daisyUI modal, driven by the server (open while rendered). Escape and a click on the
  # backdrop send "close_modal"; the first control takes focus when it opens.
  defp modal(assigns) do
    ~H"""
    <div
      id="new-link-modal"
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby="new-link-title"
      phx-window-keydown="close_modal"
      phx-key="Escape"
      phx-mounted={JS.focus_first()}
    >
      <div class="modal-box">
        <h2 id="new-link-title" class="mb-4 text-lg font-semibold">{@title}</h2>
        {render_slot(@inner_block)}
      </div>
      <div class="modal-backdrop" phx-click="close_modal"></div>
    </div>
    """
  end

  attr :field, :atom, required: true
  attr :errors, :map, required: true

  defp field_error(assigns) do
    ~H"""
    <p :if={@errors[@field]} role="alert" data-test={"error-#{@field}"} class="text-error text-sm">
      {@errors[@field]}
    </p>
    """
  end

  defp product, do: @product

  defp display_name(name) when is_binary(name), do: String.trim(name)
  defp display_name(_name), do: ""

  # Up to two initials; "?" when the name is blank.
  defp initials(name) do
    case name |> display_name() |> String.split() |> Enum.take(2) do
      [] -> "?"
      words -> words |> Enum.map_join(&String.first/1) |> String.upcase()
    end
  end

  defp kind_label(true), do: "alias"
  defp kind_label(_generated), do: "gerado"

  # dd/mm/yyyy in UTC: compact and independent of the clock.
  defp short_date(%DateTime{} = at), do: Calendar.strftime(at, "%d/%m/%Y")
end
