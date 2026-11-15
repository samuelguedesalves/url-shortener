defmodule WriteApi.Auth.JwksFetcher do
  @moduledoc """
  Fetches Google's public signing keys (a JWKS). `config :write_api, :jwks_fetcher` picks the
  implementation; `WriteApi.Auth.Jwks` caches the result for `max_age` seconds.
  """

  @callback fetch() :: {:ok, %{keys: [map()], max_age: non_neg_integer()}} | {:error, term()}

  defmodule Httpc do
    @moduledoc "Fetches Google's JWKS over HTTPS with `:httpc`, reading `max-age` from `cache-control`."
    @behaviour WriteApi.Auth.JwksFetcher

    @url ~c"https://www.googleapis.com/oauth2/v3/certs"
    # Seconds to cache the keys when the response has no usable max-age.
    @default_max_age 300

    @impl true
    def fetch do
      request = {@url, [{~c"accept", ~c"application/json"}]}
      http_options = [timeout: 4_000, connect_timeout: 2_000, ssl: ssl_options()]

      case :httpc.request(:get, request, http_options, body_format: :binary) do
        {:ok, {{_, 200, _}, headers, body}} -> parse(headers, body)
        {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp parse(headers, body) do
      case Jason.decode(body) do
        {:ok, %{"keys" => keys}} when is_list(keys) ->
          {:ok, %{keys: keys, max_age: max_age(headers)}}

        _ ->
          {:error, :invalid_jwks}
      end
    end

    defp max_age(headers) do
      with {_, value} <- List.keyfind(headers, ~c"cache-control", 0),
           [_, seconds] <- Regex.run(~r/max-age=(\d+)/, List.to_string(value)) do
        String.to_integer(seconds)
      else
        _ -> @default_max_age
      end
    end

    defp ssl_options do
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    end
  end
end
