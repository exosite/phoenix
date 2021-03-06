defmodule Phoenix.Controller.Pipeline do
  @moduledoc false

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Plug

      require Phoenix.Endpoint
      import Phoenix.Controller.Pipeline

      Module.register_attribute(__MODULE__, :plugs, accumulate: true)
      @before_compile Phoenix.Controller.Pipeline
      @phoenix_log_level Keyword.get(opts, :log, :debug)
      @phoenix_fallback :unregistered

      @doc false
      def init(opts), do: opts

      @doc false
      def call(conn, action) when is_atom(action) do
        conn = update_in conn.private,
                 &(&1 |> Map.put(:phoenix_controller, __MODULE__)
                      |> Map.put(:phoenix_action, action))

        Phoenix.Endpoint.instrument conn, :phoenix_controller_call,
          %{conn: conn, log_level: @phoenix_log_level}, fn ->
          phoenix_controller_pipeline(conn, action)
        end
      end

      @doc false
      def action(%Plug.Conn{private: %{phoenix_action: action}} = conn, _options) do
        apply(__MODULE__, action, [conn, conn.params])
      end

      defoverridable [init: 1, call: 2, action: 2]
    end
  end

  @doc false
  def __action_fallback__(plug) do
    quote bind_quoted: [plug: plug] do
      @phoenix_fallback Phoenix.Controller.Pipeline.validate_fallback(
        plug,
        __MODULE__,
        Module.get_attribute(__MODULE__, :phoenix_fallback))
    end
  end

  @doc false
  def validate_fallback(plug, module, fallback) do
    cond do
      fallback == nil ->
        raise """
        action_fallback can only be called when using Phoenix.Controller.
        Add `use Phoenix.Controller` to #{inspect module}
        """

      fallback != :unregistered ->
        raise "action_fallback can only be called a single time per controller."

      not is_atom(plug) ->
        raise ArgumentError, "expected action_fallback to be a module or function plug, got #{inspect plug}"

      fallback == :unregistered ->
        case Atom.to_charlist(plug) do
          ~c"Elixir." ++ _ -> {:module, plug}
          _                -> {:function, plug}
        end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    action = {:action, [], true}
    plugs  = [action|Module.get_attribute(env.module, :plugs)]
    {conn, body} = Plug.Builder.compile(env, plugs, log_on_halt: :debug)
    fallback_ast =
      env.module
      |> Module.get_attribute(:phoenix_fallback)
      |> build_fallback()

    quote do
      defoverridable [action: 2]
      def action(var!(conn_before), opts) do
        try do
          var!(conn_after) = super(var!(conn_before), opts)
          unquote(fallback_ast)
        catch
          kind, reason ->
            Phoenix.Controller.Pipeline.__catch__(
              var!(conn_before), kind, reason, __MODULE__,
              var!(conn_before).private.phoenix_action,
              System.stacktrace()
            )
        end
      end

      defp phoenix_controller_pipeline(unquote(conn), var!(action)) do
        var!(conn) = unquote(conn)
        var!(controller) = __MODULE__
        _ = var!(conn)
        _ = var!(controller)
        _ = var!(action)

        unquote(body)
      end
    end
  end

  defp build_fallback(:unregistered) do
    quote do: var!(conn_after)
  end
  defp build_fallback({:module, plug}) do
    quote bind_quoted: binding() do
      case var!(conn_after) do
        %Plug.Conn{} = conn_after -> conn_after
        val -> plug.call(var!(conn_before), plug.init(val))
      end
    end
  end
  defp build_fallback({:function, plug}) do
    quote do
      case var!(conn_after) do
        %Plug.Conn{} = conn_after -> conn_after
        val -> unquote(plug)(var!(conn_before), val)
      end
    end
  end

  @doc false
  def __catch__(%Plug.Conn{}, :error, :function_clause, controller, action,
                [{controller, action, [%Plug.Conn{} = conn | _], _loc} | _] = stack) do
    args = [controller: controller, action: action, params: conn.params]
    reraise Phoenix.ActionClauseError, args, stack
  end
  def __catch__(%Plug.Conn{} = conn, kind, reason, _controller, _action, _stack) do
    Plug.Conn.WrapperError.reraise(conn, kind, reason)
  end

  @doc """
  Stores a plug to be executed as part of the plug pipeline.
  """
  defmacro plug(plug)

  defmacro plug({:when, _, [plug, guards]}), do:
    plug(plug, [], guards)

  defmacro plug(plug), do:
    plug(plug, [], true)

  @doc """
  Stores a plug with the given options to be executed as part of
  the plug pipeline.
  """
  defmacro plug(plug, opts)

  defmacro plug(plug, {:when, _, [opts, guards]}), do:
    plug(plug, opts, guards)

  defmacro plug(plug, opts), do:
    plug(plug, opts, true)

  defp plug(plug, opts, guards) do
    quote do
      @plugs {unquote(plug), unquote(opts), unquote(Macro.escape(guards))}
    end
  end
end
