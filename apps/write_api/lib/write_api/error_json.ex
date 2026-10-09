defmodule WriteApi.ErrorJSON do
  @moduledoc "JSON bodies for errors raised before a controller runs (bad JSON, 404, 415...)."

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
