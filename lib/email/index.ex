defmodule Rivet.Email do
  @moduledoc """

  sendto(recips, template, assigns \\ %{}, configs \\ [])

  - `recips` can be one or list of: user id, a `user_model`, or a `email_model`
  - `assigns` (optional) is a dictionary with key/value attributes used in the
    eex template processing.
  - `configs` is a list of configs to load, as either a config name string,
    or as a tuple of {configname, sitename} if it is site specific (the latter
    will fall back to just configname if no sitename is found in configs).

  Returns a tuple of :ok or :error with a list of results from each send.
  It will stop at the first error, however, and not continue.
  """

  def mailer(), do: Application.get_env(:rivet_email, :mailer)
  def configurator(), do: Application.get_env(:rivet_email, :configurator)

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @user_model Keyword.get(opts, :user_model, Rivet.Ident.User)
      @email_model Keyword.get(opts, :email_model, Rivet.Ident.Email)
      @backend Keyword.get(opts, :backend)
      require Logger

      @type email_model() :: @email_model.t()
      @type user_model() :: @user_model.t()
      @type user_id() :: String.t()
      @type email_recipient() :: email_model() | user_model() | user_id()

      # future: changes assigns to opts and allow for more than just 'site'
      # config data to be imported from Db
      def sendto(recips, template, assigns \\ [], configs \\ [])

      def sendto([], template, assigns, configs),
        do: Logger.error("Cannot send email to no recipients!", template: template)

      def sendto(recips, template, assigns, configs) do
        with {:ok, emails} <- get_emails(recips),
             {:ok, assigns} <- generate_assigns(assigns, configs) do
          send_all(emails, template, assigns, [])
        end
      end

      ##########################################################################
      defp send_all([recip | rest], template, assigns, out) when is_map(assigns) do
        case deliver(recip, template, assigns) do
          {:ok, result} -> send_all(rest, template, assigns, [result | out])
          error -> {:error, error, [out] |> Enum.reverse()}
        end
      end

      defp send_all([], _, _, out), do: {:ok, Enum.reverse(out)}

      ##########################################################################
      # future: for scale of thousands/second, add a read-through cache with Rivet lazy cache
      defp get_config(name), do: Rivet.Email.configurator().get(name)

      defp reduce_load_config(name, {:ok, cfgs}) do
        case get_config("site") do
          {:ok, config} -> {:cont, {:ok, Map.merge(cfgs, config)}}
          error -> {:halt, error}
        end
      end

      ##########################################################################
      def generate_assigns(assigns, configs) do
        with {:ok, cfgs} <- Enum.reduce_while(configs, {:ok, %{}}, &reduce_load_config/2) do
          assigns = Map.merge(cfgs, Map.new(assigns))

          # site config is merged into one, allowing assigns to override things
          case Map.get(assigns, :email_from) do
            nil -> {:error, ":email_from missing"}
            [name, email] -> {:ok, Map.put(assigns, :email_from, {name, email})}
            from -> {:ok, Map.put(assigns, :email_from, from)}
          end
        end
      end

      ##########################################################################
      @spec deliver(recipient :: any(), template :: atom(), assigns :: map()) ::
              {:ok, Swoosh.Email.t()} | {:error, term()}
      def deliver(%@email_model{} = recipient, template, assigns) do
        # the only magic value
        assigns = Map.put(assigns, :recipient, recipient)

        case template.generate(recipient, assigns) do
          {:ok, subject, body} ->
            Swoosh.Email.new(to: recipient.address, from: assigns.email_from)
            |> Swoosh.Email.subject(subject)
            |> Swoosh.Email.html_body("<html><body>#{body}</body></html>")
            |> Swoosh.Email.text_body(Rivet.Email.Template.html2text(body))
            |> send_email()

          {:error, "Nothing found"} ->
            Logger.error("Cannot send email; template missing!", template: template)

          other ->
            Logger.debug("error processing template", error: other)
            IO.inspect(other)
            {:error, :invalid_template_result}
        end
      end

      ##########################################################################
      def send_email(%Swoosh.Email{to: [{_, eaddr} = addr], subject: subj} = email) do
        if Application.get_env(:rivet_email, :enabled) do
          if String.ends_with?("@example.com", eaddr) do
            {:error, :example_email}
          else
            Logger.debug("sending email", to: eaddr, from: email.from, subject: subj)
            @backend.deliver(email)
          end
        else
          Logger.warning("Email disabled, not sending message to #{inspect(addr)}", subject: subj)
          log_email(email)
          {:ok, "email disabled"}
        end
      end

      ##########################################################################
      def log_email(%Swoosh.Email{} = email) do
        Logger.warning("""
        Subject: #{email.subject}
        --- html
        #{email.html_body}
        --- text
        #{email.text_body}
        """)
      end

      ##########################################################################
      # future: assigns can include verfied: true (or some way to only send to verified addresses)
      @spec get_emails(email_recipient() | list(email_recipient)) ::
              {:ok, list(email_model())} | {:error, String.t(), term()}

      def get_emails(recip, out \\ [])

      def get_emails([recip | recips], out) do
        with {:ok, email} <- get_email(recip) do
          get_emails(recips, [email | out])
        else
          {:error, %{reason: :no_email, user: user}} ->
            {:error, "Unable to load email for user, cannot send email", user: user.id}

          err ->
            {:error, "Unable to find email", err}
        end
      end

      def get_emails([], out), do: {:ok, out}
      def get_emails(recip, out), do: get_emails([recip], out)

      ##########################################################################
      @spec get_email(email_recipient()) :: {:ok, email_model()} | {:error, reason :: any()}
      def get_email(%@email_model{} = email) do
        with {:ok, %@email_model{} = email} <- @email_model.preload(email, [:user]) do
          {:ok, email}
        end
      end

      # TODO: verified should be a settable option
      def get_email(%@user_model{} = user) do
        with {:ok, %@user_model{emails: emails}} <- @user_model.preload(user, [:emails]) do
          case Enum.find(emails, fn e -> e.verified end) do
            %@email_model{} = email ->
              {:ok, %@email_model{email | user: user}}

            _ ->
              with %@email_model{} = email <- List.first(emails) do
                {:ok, %@email_model{email | user: user}}
              else
                _ ->
                  {:error, :no_email}
              end
          end
        end
      end

      def get_email(user_id) when is_binary(user_id) do
        with {:ok, user} <- @user_model.one(user_id) do
          get_email(user)
        end
      end
    end
  end
end
