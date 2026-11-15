defmodule ShortenerCore.UsersTest do
  use ExUnit.Case, async: false

  alias ShortenerCore.{User, UserStore, Users, Uuid}

  setup do
    start_supervised!(ShortenerCore.UserStore.Memory)
    :ok
  end

  # The claims of a Google ID token that `register_or_update/2` reads.
  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "sub" => "109876543210987654321",
        "email" => "ada@example.com",
        "email_verified" => true,
        "name" => "Ada Lovelace",
        "picture" => "https://example.com/ada.jpg"
      },
      overrides
    )
  end

  defp at(second), do: ~U[2026-11-09 13:00:00.000Z] |> DateTime.add(second, :second)

  describe "first login" do
    test "creates a user from the Google claims" do
      assert {:ok, %User{} = user} = Users.register_or_update(claims(), at(0))

      assert user.google_id == "109876543210987654321"
      assert user.email == "ada@example.com"
      assert user.name == "Ada Lovelace"
      assert user.picture_url == "https://example.com/ada.jpg"
      assert user.email_verified == true
      assert user.created_at == at(0)
      assert user.updated_at == at(0)

      assert user.id =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    end

    test "the id is the application's own, not the Google sub" do
      assert {:ok, user} = Users.register_or_update(claims(), at(0))
      refute user.id == user.google_id
    end

    test "persists the user so it can be found by id and by google id" do
      assert {:ok, user} = Users.register_or_update(claims(), at(0))
      assert UserStore.get(user.id) == {:ok, user}
      assert UserStore.get_by_google_id(user.google_id) == {:ok, user}
    end

    test "a missing picture is stored as nil" do
      assert {:ok, %User{picture_url: nil}} =
               Users.register_or_update(Map.delete(claims(), "picture"), at(0))
    end

    test "a missing name falls back to the email" do
      assert {:ok, %User{name: "ada@example.com"}} =
               Users.register_or_update(Map.delete(claims(), "name"), at(0))
    end

    test "email_verified is false when the claim is missing" do
      assert {:ok, %User{email_verified: false}} =
               Users.register_or_update(Map.delete(claims(), "email_verified"), at(0))
    end

    test "email_verified accepts the string form some Google endpoints return" do
      assert {:ok, %User{email_verified: true}} =
               Users.register_or_update(claims(%{"email_verified" => "true"}), at(0))

      assert {:ok, %User{email_verified: false}} =
               Users.register_or_update(
                 claims(%{"sub" => "2", "email_verified" => "false"}),
                 at(0)
               )
    end
  end

  describe "returning user" do
    test "is recognised by the Google sub and keeps the same id and created_at" do
      assert {:ok, first} = Users.register_or_update(claims(), at(0))
      assert {:ok, second} = Users.register_or_update(claims(), at(60))

      assert second.id == first.id
      assert second.created_at == first.created_at
    end

    test "an unchanged profile leaves updated_at alone and does not rewrite the row" do
      assert {:ok, first} = Users.register_or_update(claims(), at(0))
      assert {:ok, second} = Users.register_or_update(claims(), at(60))

      assert second.updated_at == at(0)
      assert second == first
    end

    test "a changed profile is saved and bumps updated_at" do
      assert {:ok, first} = Users.register_or_update(claims(), at(0))

      changed =
        claims(%{
          "name" => "Ada King",
          "email" => "ada@new.example.com",
          "picture" => "https://example.com/new.jpg",
          "email_verified" => false
        })

      assert {:ok, second} = Users.register_or_update(changed, at(60))

      assert second.id == first.id
      assert second.created_at == at(0)
      assert second.updated_at == at(60)
      assert second.name == "Ada King"
      assert second.email == "ada@new.example.com"
      assert second.picture_url == "https://example.com/new.jpg"
      assert second.email_verified == false
      assert UserStore.get(first.id) == {:ok, second}
    end

    test "a picture removed at Google is cleared" do
      assert {:ok, _} = Users.register_or_update(claims(), at(0))

      assert {:ok, %User{picture_url: nil}} =
               Users.register_or_update(Map.delete(claims(), "picture"), at(60))
    end

    test "never matches on email: a different sub with the same email is a different user" do
      assert {:ok, first} = Users.register_or_update(claims(), at(0))
      assert {:ok, second} = Users.register_or_update(claims(%{"sub" => "999"}), at(1))
      refute second.id == first.id
    end
  end

  describe "invalid claims" do
    defp assert_invalid(claims) do
      assert Users.register_or_update(claims, at(0)) == {:error, :invalid_claims}
      assert UserStore.get_by_google_id("109876543210987654321") == :not_found
    end

    test "no sub is rejected and nothing is stored" do
      assert_invalid(Map.delete(claims(), "sub"))
    end

    test "a blank sub is rejected and nothing is stored" do
      assert_invalid(claims(%{"sub" => ""}))
    end

    test "a non-string sub is rejected and nothing is stored" do
      assert_invalid(claims(%{"sub" => 109_876_543_210_987_654_321}))
    end

    test "no email is rejected and nothing is stored" do
      assert_invalid(Map.delete(claims(), "email"))
    end

    test "a blank email is rejected and nothing is stored" do
      assert_invalid(claims(%{"email" => "  "}))
    end

    test "a non-map is rejected" do
      assert Users.register_or_update(nil, at(0)) == {:error, :invalid_claims}
    end
  end

  describe "consistency between the two tables" do
    test "simultaneous first logins create exactly one user" do
      results =
        1..20
        |> Task.async_stream(fn _ -> Users.register_or_update(claims()) end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %User{}}, &1))
      ids = results |> Enum.map(fn {:ok, user} -> user.id end) |> Enum.uniq()
      assert [id] = ids
      assert {:ok, %User{id: ^id}} = UserStore.get_by_google_id("109876543210987654321")
    end

    test "a google id claimed by a crashed registration is completed on the next login" do
      orphan_id = Uuid.generate()
      assert UserStore.claim_google_id("109876543210987654321", orphan_id) == {:ok, orphan_id}
      assert UserStore.get(orphan_id) == :not_found

      assert {:ok, %User{id: ^orphan_id} = user} = Users.register_or_update(claims(), at(0))
      assert UserStore.get(orphan_id) == {:ok, user}
    end
  end

  describe "when the store is unavailable" do
    setup do
      previous = Application.fetch_env!(:shortener_core, :user_store)
      Application.put_env(:shortener_core, :user_store, ShortenerCore.UserStore.Unavailable)
      on_exit(fn -> Application.put_env(:shortener_core, :user_store, previous) end)
    end

    test "register_or_update returns {:error, :unavailable}" do
      assert Users.register_or_update(claims(), at(0)) == {:error, :unavailable}
    end
  end
end
