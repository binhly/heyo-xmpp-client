module Xmpp
  class Plugin
    def self.plugin_id
      name.split("::").last
          .gsub(/([a-z])([A-Z])/, "\\1_\\2")
          .downcase
          .to_sym
    end

    def initialize(client, **_options)
      @client = client
    end

    attr_reader :client

    def plugin_id
      self.class.plugin_id
    end

    def on_connect; end

    def on_disconnect(error: nil); end

    def on_stream_features(_features); end

    def on_stanza(_stanza); end

    def before_send(_xml); end

    def sasl_authenticate(_client, _features)
      nil
    end
  end
end
