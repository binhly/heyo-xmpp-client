module Xmpp
  class PluginManager
    def initialize(logger: nil)
      @logger = logger
      @plugins = []
      @plugins_by_id = {}
    end

    def register(plugin_class, client, **options)
      plugin = plugin_class.new(client, **options)
      @plugins << plugin
      @plugins_by_id[plugin.plugin_id] = plugin
      plugin
    end

    def fetch(id)
      return nil unless id
      @plugins_by_id[id.to_sym]
    end

    def all
      @plugins.dup
    end

    def on_connect
      @plugins.each { |plugin| safe_call(plugin, :on_connect) }
    end

    def on_disconnect(error: nil)
      @plugins.each { |plugin| safe_call(plugin, :on_disconnect, error: error) }
    end

    def on_stream_features(features)
      @plugins.each { |plugin| safe_call(plugin, :on_stream_features, features) }
    end

    def on_stanza(stanza)
      @plugins.each { |plugin| safe_call(plugin, :on_stanza, stanza) }
    end

    def before_send(xml)
      @plugins.reduce(xml) do |memo, plugin|
        updated = safe_call(plugin, :before_send, memo)
        updated.is_a?(String) ? updated : memo
      end
    end

    def sasl_authenticate(client, features)
      @plugins.each do |plugin|
        result = safe_call(plugin, :sasl_authenticate, client, features)
        return result unless result.nil?
      end
      nil
    end

    private

    def safe_call(plugin, method, *args, **kwargs)
      plugin.public_send(method, *args, **kwargs)
    rescue StandardError => e
      log("Plugin #{plugin.class} #{method} error: #{e}")
      nil
    end

    def log(message)
      return unless @logger
      @logger.call(message)
    end
  end
end
