# frozen_string_literal: true

module Agents
  module Tracing
    class SessionContext
      SESSION_ID_KEY = :agents_session_id

      def self.with_session(session_id)
        unless defined?(OpenTelemetry::Context)
          yield
          return
        end

        token = OpenTelemetry::Context.attach(
          OpenTelemetry::Context.current.set_value(SESSION_ID_KEY, session_id)
        )
        yield
      ensure
        OpenTelemetry::Context.detach(token) if token
      end

      def self.current_session_id
        return nil unless defined?(OpenTelemetry::Context)
        
        OpenTelemetry::Context.current.value(SESSION_ID_KEY)
      end
    end
  end
end