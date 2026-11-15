defmodule WriteApi.DashboardCreateTest do
  use WriteApi.DashboardCase, async: false

  alias ShortenerCore.UrlStore
  alias WriteApi.{Doubles, Links, Session}
  alias WriteApi.Doubles.DownStore

  @url "https://example.com/a/very/long/path"

  defp rows(view) do
    view
    |> element("#links")
    |> render()
    |> then(&Regex.scan(~r/id="(links-[^"]+)"/, &1))
    |> Enum.map(&List.last/1)
  end

  defp open(user_id) do
    user!(user_id)
    {:ok, view, _html} = live(signed_in_conn(user_id), "/dashboard")
    view |> element(~s(button[phx-click="open_modal"]), "+ Novo link") |> render_click()
    view
  end

  defp submit(view, params), do: view |> form("#new-link-form", params) |> render_submit()

  defp owned_links(user_id) do
    {:ok, %{links: links}} = Links.page(user_id, %{})
    links
  end

  describe "the modal" do
    test "open_modal shows the form with Gerar automaticamente selected and no alias field" do
      view = open("alice")

      assert has_element?(view, ~s(#new-link-modal[role="dialog"]))
      assert has_element?(view, ~s(#new-link-form input[name="url"]))

      assert has_element?(
               view,
               ~s(button[role="radio"][aria-checked="true"]),
               "Gerar automaticamente"
             )

      assert has_element?(view, ~s(button[role="radio"][aria-checked="false"]), "Escolher alias")
      refute has_element?(view, ~s(#new-link-form input[name="alias"]))
      assert has_element?(view, ~s([data-test="address-preview"]), "localhost:4002/")
    end

    test "set_mode alias reveals the alias input with the redirect host as prefix" do
      view = open("alice")

      view |> element("button", "Escolher alias") |> render_click()

      assert has_element?(view, ~s(#new-link-form input[name="alias"]))
      assert has_element?(view, ~s(button[role="radio"][aria-checked="true"]), "Escolher alias")
      assert has_element?(view, ~s([data-test="alias-prefix"]), "localhost:4002/")
      refute has_element?(view, ~s([data-test="address-preview"]))
    end

    test "the address prefix is the host of the redirect base url" do
      Doubles.swap_env(:write_api, :base_url, "https://sho.rt")
      view = open("alice")
      view |> element("button", "Escolher alias") |> render_click()

      assert has_element?(view, ~s([data-test="alias-prefix"]), "sho.rt/")
      refute has_element?(view, ~s([data-test="alias-prefix"]), "localhost")
    end

    test "the expiry select offers the presets, 10 anos (padrão) selected, none above the maximum" do
      view = open("alice")

      options =
        view
        |> element(~s(#new-link-form select[name="ttl_seconds"]))
        |> render()
        |> then(&Regex.scan(~r/<option[^>]*value="(\d+)"[^>]*>\s*([^<]+?)\s*<\/option>/, &1))
        |> Enum.map(fn [_, seconds, label] -> {String.to_integer(seconds), label} end)

      assert options == [
               {3600, "1 hora"},
               {86_400, "1 dia"},
               {604_800, "7 dias"},
               {2_592_000, "30 dias"},
               {31_536_000, "1 ano"},
               {315_360_000, "10 anos (padrão)"}
             ]

      max = Application.fetch_env!(:shortener_core, :max_link_ttl)
      assert Enum.all?(options, fn {seconds, _} -> seconds <= max end)
      assert has_element?(view, ~s(#new-link-form option[value="315360000"][selected]))
    end

    test "presets above a lowered maximum are not offered" do
      Doubles.swap_env(:shortener_core, :max_link_ttl, 700_000)
      Doubles.swap_env(:shortener_core, :default_link_ttl, 700_000)
      view = open("alice")

      refute has_element?(view, ~s(option[value="2592000"]))
      refute has_element?(view, ~s(option[value="315360000"]))
      assert has_element?(view, ~s(option[value="604800"][selected]), "7 dias (padrão)")
    end

    test "close_modal returns to the list and the form resets on reopen" do
      view = open("alice")
      view |> element("button", "Escolher alias") |> render_click()

      view
      |> form("#new-link-form", %{"url" => @url, "alias" => "typed-alias"})
      |> render_change()

      view |> element("#new-link-form button", "Cancelar") |> render_click()
      refute has_element?(view, "#new-link-modal")
      assert has_element?(view, ~s([data-test="links-title"]))

      view |> element(~s(button[phx-click="open_modal"]), "+ Novo link") |> render_click()
      assert has_element?(view, ~s(#new-link-form input[name="url"]))
      refute has_element?(view, ~s(#new-link-form input[value="#{@url}"]))
      refute has_element?(view, ~s(#new-link-form input[name="alias"]))

      assert has_element?(
               view,
               ~s(button[role="radio"][aria-checked="true"]),
               "Gerar automaticamente"
             )
    end

    test "Escape and the backdrop close the modal" do
      view = open("alice")

      assert has_element?(
               view,
               ~s(#new-link-modal[phx-window-keydown="close_modal"][phx-key="Escape"])
             )

      view |> element("#new-link-modal .modal-backdrop") |> render_click()
      refute has_element?(view, "#new-link-modal")

      view |> element(~s(button[phx-click="open_modal"]), "+ Novo link") |> render_click()
      render_keydown(view, "close_modal", %{"key" => "Escape"})
      refute has_element?(view, "#new-link-modal")
    end

    test "an alias typed earlier survives edits made in generate mode" do
      view = open("alice")
      view |> element("button", "Escolher alias") |> render_click()
      view |> form("#new-link-form", %{"alias" => "kept-alias"}) |> render_change()
      view |> element("button", "Gerar automaticamente") |> render_click()
      view |> form("#new-link-form", %{"url" => @url}) |> render_change()

      view |> element("button", "Escolher alias") |> render_click()

      assert has_element?(view, ~s(#new-link-form input[name="alias"][value="kept-alias"]))
    end

    test "switching the mode keeps what was typed" do
      view = open("alice")
      view |> form("#new-link-form", %{"url" => @url}) |> render_change()

      view |> element("button", "Escolher alias") |> render_click()

      assert has_element?(view, ~s(#new-link-form input[name="url"][value="#{@url}"]))
    end
  end

  describe "creating" do
    test "with a chosen alias adds it to the top of the list tagged alias and shows the short link" do
      view = open("alice")
      view |> element("button", "Escolher alias") |> render_click()

      submit(view, %{"url" => @url, "alias" => "meu-alias"})

      assert has_element?(
               view,
               ~s([data-test="link-created"] input[value="http://localhost:4002/meu-alias"])
             )

      assert has_element?(
               view,
               ~s([data-test="link-created"] [data-copy="http://localhost:4002/meu-alias"])
             )

      assert has_element?(view, ~s([data-test="link-created"] button[phx-hook="Copy"]))
      assert has_element?(view, ~s(#new-link-modal button), "Fechar")
      refute has_element?(view, "#new-link-form")

      assert rows(view) == ["links-meu-alias"]
      assert has_element?(view, "#links-meu-alias", "alias")
      assert has_element?(view, "#links-meu-alias", @url)
      assert has_element?(view, ~s([data-test="links-title"]), "Meus links (1)")
      refute has_element?(view, ~s([data-test="empty-state"]))
      assert [%{code: "meu-alias", is_custom_alias: true}] = owned_links("alice")
    end

    test "a new link goes on top of the existing ones" do
      user!("alice")

      {:ok, _} =
        WriteApi.Shortener.create(%{"url" => @url},
          owner_id: "alice",
          now: ~U[2026-11-05 12:00:00Z]
        )

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")
      [existing] = rows(view)
      view |> element(~s(button[phx-click="open_modal"]), "+ Novo link") |> render_click()
      view |> element("button", "Escolher alias") |> render_click()

      submit(view, %{"url" => @url, "alias" => "fresh"})

      assert rows(view) == ["links-fresh", existing]
      assert has_element?(view, ~s([data-test="links-title"]), "Meus links (2)")
    end

    test "in generate mode makes a 7-character code tagged gerado, owned by the user" do
      view = open("alice")

      submit(view, %{"url" => @url})

      assert [%{code: code, is_custom_alias: false} = link] = owned_links("alice")
      assert String.length(code) == 7
      assert link.long_url == @url
      assert {:ok, %{owner_id: "alice", long_url: @url}} = UrlStore.fetch(code)
      assert rows(view) == ["links-#{code}"]
      assert has_element?(view, "#links-#{code}", "gerado")

      assert has_element?(
               view,
               ~s([data-test="link-created"] input[value="http://localhost:4002/#{code}"])
             )
    end

    test "an alias typed while in generate mode is ignored" do
      view = open("alice")
      view |> element("button", "Escolher alias") |> render_click()

      view
      |> form("#new-link-form", %{"url" => @url, "alias" => "ghost-alias"})
      |> render_change()

      view |> element("button", "Gerar automaticamente") |> render_click()

      view
      |> form("#new-link-form", %{"url" => @url})
      |> render_submit(%{"alias" => "ghost-alias"})

      assert [%{code: code, is_custom_alias: false}] = owned_links("alice")
      assert code != "ghost-alias"
      assert :not_found = UrlStore.fetch("ghost-alias")
    end

    test "the chosen expiry is sent as seconds; a blank one is omitted" do
      view = open("alice")
      before = DateTime.utc_now()
      submit(view, %{"url" => @url, "ttl_seconds" => "3600"})
      [one_hour] = owned_links("alice")
      assert DateTime.diff(one_hour.expires_at, before) in 3599..3601

      view |> element(~s(#new-link-modal button), "Fechar") |> render_click()
      view |> element(~s(button[phx-click="open_modal"]), "+ Novo link") |> render_click()
      render_submit(view, "create", %{"url" => @url <> "2", "ttl_seconds" => ""})

      [default, _] = owned_links("alice")
      default_ttl = Application.fetch_env!(:shortener_core, :default_link_ttl)

      assert DateTime.diff(default.expires_at, DateTime.utc_now()) in (default_ttl - 2)..default_ttl
    end

    test "the submit button disables itself while submitting" do
      view = open("alice")
      assert has_element?(view, ~s(#new-link-form button[type="submit"][phx-disable-with]))
    end

    test "a second create after success creates nothing" do
      view = open("alice")
      params = %{"url" => @url, "alias" => "", "ttl_seconds" => "3600"}

      render_submit(view, "create", params)
      render_submit(view, "create", params)
      render_submit(view, "create", %{params | "url" => "https://example.com/other"})

      assert [%{long_url: @url}] = owned_links("alice")
      assert length(rows(view)) == 1
      assert has_element?(view, ~s([data-test="links-title"]), "Meus links (1)")
    end

    test "a create with no modal open creates nothing" do
      user!("alice")
      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      render_submit(view, "create", %{"url" => @url})

      assert owned_links("alice") == []
    end
  end

  describe "errors" do
    test "a taken alias keeps the modal open with Esse alias já está em uso, creates nothing" do
      user!("bob")

      {:ok, _} =
        WriteApi.Shortener.create(%{"url" => @url, "custom_alias" => "taken"}, owner_id: "bob")

      view = open("alice")
      view |> element("button", "Escolher alias") |> render_click()

      submit(view, %{"url" => "https://example.com/mine", "alias" => "taken"})

      assert has_element?(view, ~s([data-test="error-alias"]), "Esse alias já está em uso")
      assert has_element?(view, ~s(#new-link-form input[name="alias"][value="taken"]))

      assert has_element?(
               view,
               ~s(#new-link-form input[name="url"][value="https://example.com/mine"])
             )

      refute has_element?(view, ~s([data-test="link-created"]))
      assert owned_links("alice") == []
      assert rows(view) == []
    end

    test "a blank alias in alias mode is rejected on the alias field, not turned into a code" do
      view = open("alice")
      view |> element("button", "Escolher alias") |> render_click()

      for blank <- ["", "   "] do
        submit(view, %{"url" => @url, "alias" => blank})

        assert has_element?(view, ~s([data-test="error-alias"]), "Alias inválido")
        assert has_element?(view, ~s(#new-link-form input[name="url"][value="#{@url}"]))
        assert has_element?(view, ~s(#new-link-form input[name="alias"][value="#{blank}"]))
        refute has_element?(view, ~s([data-test="link-created"]))
        assert owned_links("alice") == []
        assert rows(view) == []
      end
    end

    test "an invalid or reserved alias, an invalid url and an invalid ttl show their messages" do
      view = open("alice")
      view |> element("button", "Escolher alias") |> render_click()

      submit(view, %{"url" => @url, "alias" => "auth"})
      assert has_element?(view, ~s([data-test="error-alias"]), "Alias inválido")
      refute has_element?(view, ~s([data-test="error-url"]))
      assert has_element?(view, ~s(#new-link-form input[name="alias"][value="auth"]))

      submit(view, %{"url" => "not a url", "alias" => "fine-alias"})
      assert has_element?(view, ~s([data-test="error-url"]), "URL válida")
      refute has_element?(view, ~s([data-test="error-alias"]))
      assert has_element?(view, ~s(#new-link-form input[name="url"][value="not a url"]))

      view |> element("button", "Gerar automaticamente") |> render_click()
      render_submit(view, "create", %{"url" => @url, "alias" => "", "ttl_seconds" => "0"})
      assert has_element?(view, ~s([data-test="error-ttl_seconds"]), "prazo")

      render_submit(view, "create", %{"url" => @url, "alias" => "", "ttl_seconds" => "abc"})
      assert has_element?(view, ~s([data-test="error-ttl_seconds"]), "prazo")

      assert owned_links("alice") == []
      assert has_element?(view, "#new-link-form")
    end

    test "an error goes away on the next successful create and its field edit" do
      view = open("alice")
      submit(view, %{"url" => "nope"})
      assert has_element?(view, ~s([data-test="error-url"]))

      view
      |> form("#new-link-form", %{"url" => "https://example.com/x"})
      |> render_change(%{"_target" => ["url"]})

      refute has_element?(view, ~s([data-test="error-url"]))
    end

    test "store down on create keeps the modal open with an unavailable message" do
      view = open("alice")
      Doubles.swap_env(:shortener_core, :url_store, DownStore)

      submit(view, %{"url" => @url})

      assert has_element?(view, ~s([data-test="error-general"]), "temporariamente indisponível")
      assert has_element?(view, ~s(#new-link-form input[name="url"][value="#{@url}"]))
      refute has_element?(view, ~s([data-test="link-created"]))
      assert rows(view) == []
    end

    test "a user store blip on create redirects to /dashboard like a signed out session" do
      view = open("alice")
      Doubles.swap_env(:shortener_core, :user_store, Doubles.DownUserStore)

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               view |> form("#new-link-form", %{"url" => @url}) |> render_submit()
    end

    test "create after the cookie expired redirects to /dashboard and creates nothing" do
      user!("alice")
      conn = signed_in_conn("alice", now: DateTime.add(DateTime.utc_now(), -10))
      {:ok, view, _html} = live(conn, "/dashboard")
      view |> element(~s(button[phx-click="open_modal"]), "+ Novo link") |> render_click()

      Doubles.swap_env(:write_api, :session_ttl, 5)

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               view |> form("#new-link-form", %{"url" => @url}) |> render_submit()

      assert owned_links("alice") == []
    end
  end

  describe "what the page shows" do
    test "the raw session cookie is absent from the modal, in every state" do
      user!("alice")
      raw = Session.issue(build_conn(), "alice").resp_cookies["session"].value
      {:ok, view, _html} = live(put_req_cookie(build_conn(), "session", raw), "/dashboard")

      view |> element(~s(button[phx-click="open_modal"]), "+ Novo link") |> render_click()
      assert has_element?(view, "#new-link-modal")
      refute render(view) =~ raw

      submit(view, %{"url" => "nope"})
      refute render(view) =~ raw

      submit(view, %{"url" => @url})
      assert has_element?(view, ~s([data-test="link-created"]))
      refute render(view) =~ raw
    end

    test "the list copy buttons carry the Copy hook and keep data-copy" do
      user!("alice")

      {:ok, _} =
        WriteApi.Shortener.create(%{"url" => @url, "custom_alias" => "abc"}, owner_id: "alice")

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(
               view,
               ~s(#links-abc button[phx-hook="Copy"][data-copy="http://localhost:4002/abc"])
             )
    end
  end
end
