defmodule WriteApi.DashboardListTest do
  use WriteApi.DashboardCase, async: false

  alias ShortenerCore.{Url, UrlStore}
  alias WriteApi.Doubles
  alias WriteApi.Doubles.DownStore
  alias WriteApi.Session

  @base ~U[2026-11-05 12:00:00.000Z]
  @far_future ~U[2099-01-01 00:00:00.000Z]

  # Stores a link for `owner` created `offset` seconds after @base. Without a destination it
  # reads as expired (ADR 0004).
  defp link!(owner, code, offset, opts \\ []) do
    :ok =
      UrlStore.claim(%Url{
        code: code,
        owner_id: owner,
        is_custom_alias: Keyword.get(opts, :alias, false),
        created_at: DateTime.add(@base, offset, :second),
        expires_at: @far_future
      })

    case Keyword.get(opts, :destination, "https://example.com/" <> code) do
      nil -> :ok
      destination -> UrlStore.put_destination(code, destination, 3600)
    end

    code
  end

  defp codes(n, prefix), do: for(i <- 1..n, do: "#{prefix}#{String.pad_leading("#{i}", 3, "0")}")

  defp rows(view), do: view |> element("#links") |> render() |> row_ids()

  defp row_ids(html), do: Regex.scan(~r/id="(links-[^"]+)"/, html) |> Enum.map(&List.last/1)

  describe "the list" do
    test "lists only the signed-in user's links" do
      user!("alice")
      user!("bob")
      link!("alice", "alice1", 1)
      link!("bob", "bob1", 2)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, "#links-alice1")
      refute has_element?(view, "#links-bob1")
      refute render(view) =~ "bob1"
    end

    test "orders newest first and tags alias vs generated; the row shows destination and date" do
      user!("alice")
      link!("alice", "older", 1)
      link!("alice", "meu-alias", 2, alias: true)
      link!("alice", "newest", 3)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert rows(view) == ["links-newest", "links-meu-alias", "links-older"]
      assert has_element?(view, "#links-meu-alias", "alias")
      refute has_element?(view, "#links-meu-alias", "gerado")
      assert has_element?(view, "#links-older", "gerado")
      assert has_element?(view, "#links-older", "https://example.com/older")
      assert has_element?(view, "#links-older", "05/11/2026")
      assert has_element?(view, ~s(#links-older [data-copy="http://localhost:4002/older"]))
    end

    test "an expired link is dimmed, tagged expirado, shows destino removido and no copy control" do
      user!("alice")
      link!("alice", "gone", 1, destination: nil)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s(#links-gone[data-status="expired"]))
      assert has_element?(view, "#links-gone.opacity-60")
      assert has_element?(view, "#links-gone", "expirado")
      assert has_element?(view, "#links-gone", "destino removido")
      refute has_element?(view, "#links-gone [data-copy]")
    end

    test "title shows the count and a plus sign while more pages exist" do
      user!("alice")
      for {code, i} <- Enum.with_index(codes(21, "a"), 1), do: link!("alice", code, i)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s([data-test="links-title"]), "Meus links (20+)")
    end

    test "title shows the plain count when every link is loaded" do
      user!("alice")
      link!("alice", "one", 1)
      link!("alice", "two", 2)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s([data-test="links-title"]), "Meus links (2)")
      refute render(view) =~ "(2+)"
      refute has_element?(view, "button", "Carregar mais")
    end

    test "the new link button is offered" do
      user!("alice")

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s(button[phx-click="open_modal"]), "+ Novo link")
    end

    test "an empty list shows the empty state with the create call to action" do
      user!("alice")

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s([data-test="empty-state"]))
      assert has_element?(view, ~s([data-test="empty-state"] button[phx-click="open_modal"]))
      assert has_element?(view, ~s([data-test="links-title"]), "Meus links (0)")
      refute has_element?(view, "button", "Carregar mais")
    end
  end

  describe "load_more" do
    test "appends the next page without duplicates or gaps" do
      user!("alice")
      all = codes(25, "c")
      for {code, i} <- Enum.with_index(all, 1), do: link!("alice", code, i)
      newest_first = Enum.reverse(all)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      first_page = rows(view)
      assert first_page == Enum.map(Enum.take(newest_first, 20), &"links-#{&1}")
      assert has_element?(view, "button", "Carregar mais")

      view |> element("button", "Carregar mais") |> render_click()

      assert rows(view) == Enum.map(newest_first, &"links-#{&1}")
      assert Enum.take(rows(view), 20) == first_page
      refute has_element?(view, "button", "Carregar mais")
      assert has_element?(view, ~s([data-test="links-title"]), "Meus links (25)")
      refute render(view) =~ "(25+)"
    end

    test "ignores cursor, limit and owner params sent by the client" do
      user!("alice")
      user!("bob")
      all = codes(25, "c")
      for {code, i} <- Enum.with_index(all, 1), do: link!("alice", code, i)
      link!("bob", "bob1", 100)
      newest_first = Enum.reverse(all)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      render_click(view, "load_more", %{"cursor" => "garbage", "limit" => "1", "owner" => "bob"})

      assert rows(view) == Enum.map(newest_first, &"links-#{&1}")
      refute render(view) =~ "bob1"
    end

    test "a load_more with nothing left is ignored" do
      user!("alice")
      link!("alice", "one", 1)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")
      render_click(view, "load_more", %{})

      assert rows(view) == ["links-one"]
      assert has_element?(view, ~s([data-test="links-title"]), "Meus links (1)")
    end

    test "after the cookie expired redirects to /dashboard and shows no more links" do
      user!("alice")
      all = codes(25, "c")
      for {code, i} <- Enum.with_index(all, 1), do: link!("alice", code, i)

      conn = signed_in_conn("alice", now: DateTime.add(DateTime.utc_now(), -10))
      {:ok, view, html} = live(conn, "/dashboard")
      assert html =~ "c025"
      refute html =~ "c001"

      Doubles.swap_env(:write_api, :session_ttl, 5)

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               view |> element("button", "Carregar mais") |> render_click()
    end

    test "a failing page keeps the loaded links and offers a retry" do
      user!("alice")
      all = codes(25, "c")
      for {code, i} <- Enum.with_index(all, 1), do: link!("alice", code, i)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")
      before = rows(view)

      store = Application.fetch_env!(:shortener_core, :url_store)
      Application.put_env(:shortener_core, :url_store, DownStore)
      on_exit(fn -> Application.put_env(:shortener_core, :url_store, store) end)

      view |> element("button", "Carregar mais") |> render_click()

      assert rows(view) == before
      assert has_element?(view, ~s([data-test="links-error"]))

      Application.put_env(:shortener_core, :url_store, store)
      view |> element(~s([data-test="links-error"] button), "Tentar novamente") |> render_click()

      assert length(rows(view)) == 25
      refute has_element?(view, ~s([data-test="links-error"]))
    end
  end

  describe "the store being down" do
    test "on mount shows a retryable error" do
      user!("alice")
      link!("alice", "one", 1)
      Doubles.swap_env(:shortener_core, :url_store, DownStore)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")

      assert has_element?(view, ~s([data-test="signed-in"]))
      assert has_element?(view, ~s([data-test="links-error"]), "Tentar novamente")
      refute has_element?(view, ~s([data-test="empty-state"]))
      refute has_element?(view, "#links-one")
    end

    test "retry loads the list once the store is back" do
      user!("alice")
      link!("alice", "one", 1)
      store = Application.fetch_env!(:shortener_core, :url_store)
      Application.put_env(:shortener_core, :url_store, DownStore)
      on_exit(fn -> Application.put_env(:shortener_core, :url_store, store) end)

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")
      assert has_element?(view, ~s([data-test="links-error"]))

      Application.put_env(:shortener_core, :url_store, store)
      view |> element(~s([data-test="links-error"] button), "Tentar novamente") |> render_click()

      assert has_element?(view, "#links-one")
      refute has_element?(view, ~s([data-test="links-error"]))
    end

    test "retry after the cookie expired redirects to /dashboard" do
      user!("alice")
      Doubles.swap_env(:shortener_core, :url_store, DownStore)
      conn = signed_in_conn("alice", now: DateTime.add(DateTime.utc_now(), -10))
      {:ok, view, _html} = live(conn, "/dashboard")

      Doubles.swap_env(:write_api, :session_ttl, 5)

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               view |> element(~s([data-test="links-error"] button)) |> render_click()
    end
  end

  describe "what the page shows" do
    test "a destination with HTML characters is escaped" do
      user!("alice")
      link!("alice", "xss", 1, destination: "https://example.com/?q=<script>alert(1)</script>")

      {:ok, view, _html} = live(signed_in_conn("alice"), "/dashboard")
      html = view |> element("#links-xss") |> render()

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>alert"
      refute render(view) =~ "<script>alert"
    end

    test "a user with no picture and a blank name still renders the header" do
      for name <- ["   ", ""] do
        user!("blank", %{name: name, picture_url: nil})

        {:ok, view, _html} = live(signed_in_conn("blank"), "/dashboard")

        assert has_element?(view, ~s([data-test="user-avatar"]), "?")
        assert has_element?(view, ~s([data-test="signed-in"]))
      end
    end

    test "the raw session cookie is absent from the rendered signed-in page" do
      user!("alice")
      link!("alice", "one", 1)
      raw = Session.issue(build_conn(), "alice").resp_cookies["session"].value
      conn = put_req_cookie(build_conn(), "session", raw)

      {:ok, view, html} = live(conn, "/dashboard")

      assert html =~ ~s(data-test="signed-in")
      refute html =~ raw
      refute render(view) =~ raw
    end
  end
end
