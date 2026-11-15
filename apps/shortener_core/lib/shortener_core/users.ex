defmodule ShortenerCore.Users do
  @moduledoc """
  Registers and recognises users who sign in with Google.

  `register_or_update/2` takes the claims of a verified Google ID token (string keys, as Google
  sends them): `sub`, `email`, `email_verified`, `name` and `picture`. Verifying the token is
  the caller's job; this module trusts the claims it is given and stores no token.

  Two tables cannot be written atomically, so registration claims the Google `sub` first
  (`UserStore.claim_google_id/2`) and writes the user second. Simultaneous first logins agree
  on one id, and a login that finds a claim without a user row (a crash in between) completes
  it.
  """

  alias ShortenerCore.{User, UserStore, Uuid}

  @profile_fields [:email, :name, :picture_url, :email_verified]

  @type error :: :invalid_claims | :unavailable

  @spec register_or_update(map(), DateTime.t()) :: {:ok, User.t()} | {:error, error()}
  def register_or_update(claims, now \\ DateTime.utc_now())

  def register_or_update(claims, now) when is_map(claims) do
    # Cassandra timestamps have millisecond precision; keep the returned struct identical to a re-read.
    now = DateTime.truncate(now, :millisecond)

    with {:ok, profile} <- parse(claims) do
      case UserStore.get_by_google_id(profile.google_id) do
        {:ok, user} -> update_profile(user, profile, now)
        :not_found -> register(profile, now)
        {:error, :unavailable} = error -> error
      end
    end
  end

  def register_or_update(_claims, _now), do: {:error, :invalid_claims}

  defp register(profile, now) do
    with {:ok, id} <- UserStore.claim_google_id(profile.google_id, Uuid.generate()) do
      case UserStore.get(id) do
        # Another login registered this Google account while we were claiming.
        {:ok, user} ->
          update_profile(user, profile, now)

        # Ours to write: either we won the claim or a crashed registration left it unfinished.
        :not_found ->
          save(struct!(User, Map.merge(profile, %{id: id, created_at: now, updated_at: now})))

        {:error, :unavailable} = error ->
          error
      end
    end
  end

  # `updated_at` only moves when a profile field actually changed.
  defp update_profile(user, profile, now) do
    if Map.take(user, @profile_fields) == Map.take(profile, @profile_fields) do
      {:ok, user}
    else
      save(struct!(user, Map.put(Map.take(profile, @profile_fields), :updated_at, now)))
    end
  end

  defp save(user) do
    case UserStore.put(user) do
      :ok -> {:ok, user}
      {:error, :unavailable} = error -> error
    end
  end

  defp parse(claims) do
    with {:ok, google_id} <- required_string(claims["sub"]),
         {:ok, email} <- required_string(claims["email"]) do
      {:ok,
       %{
         google_id: google_id,
         email: email,
         name: optional_string(claims["name"]) || email,
         picture_url: optional_string(claims["picture"]),
         email_verified: claims["email_verified"] in [true, "true"]
       }}
    end
  end

  defp required_string(value) do
    case optional_string(value) do
      nil -> {:error, :invalid_claims}
      string -> {:ok, string}
    end
  end

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp optional_string(_), do: nil
end
