defmodule MokaidWeb.ErrorJSON do
  def render(template, _assigns) do
    %{
      error: %{code: template, message: Phoenix.Controller.status_message_from_template(template)}
    }
  end
end
