require_relative "../xml_helpers"
require_relative "../plugin"

module Xmpp
  module Plugins
    class TokenReconnection < Xmpp::Plugin
      include Xmpp::XmlHelpers

      TokenNamespace = "erlang-solutions.com:xmpp:token-auth:0"
      Mechanism = "X-OAUTH"

      def initialize(client, auto_request: true, prefer_refresh: true)
        super(client)
        @auto_request = auto_request
        @prefer_refresh = prefer_refresh
        @access_token = nil
        @refresh_token = nil
      end

      attr_reader :access_token, :refresh_token

      def tokens
        { access_token: @access_token, refresh_token: @refresh_token }
      end

      def update_tokens(access_token: nil, refresh_token: nil)
        @access_token = access_token if access_token
        @refresh_token = refresh_token if refresh_token
      end

      def clear_tokens
        @access_token = nil
        @refresh_token = nil
      end

      def on_connect
        return unless @auto_request
        return if token_present?(@access_token) && token_present?(@refresh_token)
        request_tokens
      end

      def request_tokens
        id = @client.next_iq_id("token")
        xml = "<iq type='get' to='#{escape_attr(bare_jid)}' id='#{escape_attr(id)}'><query xmlns='#{TokenNamespace}'/></iq>"
        iq = @client.request_iq(id: id, xml: xml, allow_reconnect: true)
        raise_iq_error(iq, "Token request error") if iq.attributes["type"] == "error"
        items = child_by_name(iq, "items")
        raise "Token response missing <items>" unless items
        @access_token = child_text(items, "access_token")
        @refresh_token = child_text(items, "refresh_token")
        tokens
      end

      def sasl_authenticate(client, features)
        return nil unless features_supports_xoauth?(features)
        token, token_type = select_token
        return nil unless token
        response = client.sasl_authenticate(mechanism: Mechanism, payload: token)
        if response.name == "success"
          update_refresh_token_from_success(response) if token_type == :refresh
          return true
        end
        handle_auth_failure(token_type)
        false
      end

      private

      def bare_jid
        @client.respond_to?(:bare_jid) ? @client.bare_jid : @client.jid.to_s.split("/", 2).first
      end

      def features_supports_xoauth?(features)
        mechs = features.elements["mechanisms"]
        return false unless mechs
        mechs.elements.any? { |el| el.name == "mechanism" && el.text == Mechanism }
      end

      def select_token
        if @prefer_refresh && token_present?(@refresh_token)
          return [@refresh_token, :refresh]
        end
        if token_present?(@access_token)
          return [@access_token, :access]
        end
        if token_present?(@refresh_token)
          return [@refresh_token, :refresh]
        end
        nil
      end

      def update_refresh_token_from_success(response)
        new_token = response.text.to_s.strip
        return if new_token.empty?
        @refresh_token = new_token
      end

      def handle_auth_failure(token_type)
        case token_type
        when :refresh
          @refresh_token = nil
        when :access
          @access_token = nil
        end
      end

      def token_present?(token)
        token && !token.to_s.strip.empty?
      end
    end
  end
end
